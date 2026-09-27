package Plugins::PodcastCache::Downloader;

# Downloads episodes into the cache, one at a time, without blocking LMS, and politely.
#
# Each download is a separate process running scripts/fetch-episode.pl, which does the
# work (curl, resume on truncation, If-Range, retries). A one-second timer here reads the
# status file it writes, records the result in the cache, and picks the next job.
#
#   Plugins::PodcastCache::Downloader->fetch($episode, cb => sub { my ($path, $error) = @_ },
#       priority => PLAY | NEWEST | FIRST | BACKFILL, order => $sortKey);
#
# $episode: { url, guid, title, pubdate, feedUrl, feedTitle } - url is the enclosure url.
#
# Picking the next job:
#  - PLAY (someone pressed play) goes first and ignores the politeness gaps; it even
#    pre-empts a background download (which is stopped, keeps its partial, and goes back
#    in the queue). But if the server has asked us to wait, it fails at once, so the
#    episode streams instead.
#  - Background jobs (NEWEST, FIRST, BACKFILL, in that order; within each, by `order`)
#    wait until their server is ready (Hosts.pm: an adaptive gap, and any cooldown),
#    and while live streams are using a meaningful share of the connection.
#  - A background job the server throttles goes back in the queue (a few times); other
#    failures drop it until the next feed check, which re-queues it and resumes the partial.
#  - An episode whose file is gone (404, 410, 451) is remembered for GONE_DAYS, so feed
#    checks skip it; pressing play still tries it.

use strict;

use File::Basename qw(dirname);
use JSON::PP;
use Proc::Background;

use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::PodcastCache::Hosts;
use Plugins::PodcastCache::Plan qw(PLAY NEWEST FIRST BACKFILL);
use Plugins::PodcastCache::Status;

use constant POLL_SECS      => 1;
use constant BUSY_RECHECK   => 60;     # while streams are using the connection
use constant STREAM_SHARE   => 0.2;    # background waits if streams use more than this share
use constant MAX_THROTTLES  => 5;      # re-queues of one job after the server throttles it
use constant GONE_DAYS      => 30;     # skip an episode whose file has gone for this long

my %GONE = map { $_ => 1 } (404, 410, 451);

my $log      = logger('plugin.podcastcache');
my $prefs    = preferences('plugin.podcastcache');
my $lmsCache = Slim::Utils::Cache->new;

my $script = dirname(__FILE__) . '/scripts/fetch-episode.pl';

my @queue;      # jobs waiting
my $active;     # the job running, if any
my $hosts;      # Plugins::PodcastCache::Hosts
my $paused;     # why background downloads are waiting, for the settings page

sub hosts {
	return $hosts ||= Plugins::PodcastCache::Hosts->new(
		state  => $lmsCache->get('podcastcache-hosts') || {},
		preset => $prefs->get('politeness'),
	);
}

sub _saveHosts { $lmsCache->set('podcastcache-hosts', hosts()->state, '90days') }

# Queue an episode. Calls cb->($path) when it is on disk, or cb->(undef, $error).
sub fetch {
	my ($class, $episode, %args) = @_;

	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $key   = $cache->keyFor($episode);
	my $priority = defined $args{priority} ? $args{priority} : $args{front} ? PLAY : NEWEST;

	if (my $path = $cache->completePath($key)) {
		$args{cb}->($path) if $args{cb};
		return;
	}

	# already queued or running: wait for it too, and raise its priority if need be
	if (my ($job) = grep { $_->{key} eq $key } grep { defined } $active, @queue) {
		push @{ $job->{callbacks} }, $args{cb} if $args{cb};
		$job->{priority} = $priority if $priority < $job->{priority};
		return if $job == ($active || 0);    # already downloading
		_preempt() if $priority == PLAY;
		_next();
		return;
	}

	push @queue, {
		key       => $key,
		episode   => $episode,
		callbacks => [ $args{cb} || () ],
		priority  => $priority,
		order     => defined $args{order} ? $args{order} : 0,
		queuedAt  => time(),
	};

	main::INFOLOG && $log->info("Queued $episode->{url} (priority $priority)");

	_preempt() if $priority == PLAY;
	_next();
}

# someone is waiting to play: don't make them wait for a background download
sub _preempt {
	return unless $active && $active->{priority} != PLAY && !$active->{preempted};

	$active->{preempted} = 1;
	$active->{proc}->die;    # _poll sees it end, keeps the partial and re-queues it
}

# the servers a job depends on: the enclosure host, and the one it redirected to last time
sub _hostsFor {
	my $job = shift;
	my $host = Plugins::PodcastCache::Hosts->hostOf($job->{episode}->{url});
	my $via  = hosts()->state->{via}->{$host};
	return grep { $_ } ($host, $via && $via ne $host ? $via : ());
}

sub _readyAt {
	my $job = shift;
	my ($at) = sort { $b <=> $a } map { hosts()->readyAt($_) } _hostsFor($job);
	return $at || 0;
}

sub _coolingUntil {
	my $job = shift;
	my ($until) = sort { $b <=> $a } map { hosts()->coolingUntil($_) } _hostsFor($job);
	return $until || 0;
}

sub _next {
	return if $active || !@queue;

	Slim::Utils::Timers::killTimers(undef, \&_wake);

	# someone is waiting to play: go now, unless the server has asked us to wait
	if (my ($job) = sort { $a->{queuedAt} <=> $b->{queuedAt} } grep { $_->{priority} == PLAY } @queue) {
		@queue = grep { $_ != $job } @queue;

		if (my $until = _coolingUntil($job)) {
			_finish($job, undef, sprintf('Not downloading "%s": the server asked us to wait until %s',
				_title($job), _hhmm($until)));
			return _next();
		}

		return _start($job);
	}

	# background downloads: only when streams leave room, and their server is ready
	if (my $why = _busy()) {
		$paused = $why;
		Slim::Utils::Timers::setTimer(undef, time() + BUSY_RECHECK, \&_wake);
		return;
	}
	$paused = undef;

	my $now = time();
	my @byOrder = sort { $a->{priority} <=> $b->{priority} || $a->{order} <=> $b->{order} } @queue;

	my ($job) = grep { _readyAt($_) <= $now } @byOrder;

	if (!$job) {
		my ($soonest) = sort { $a <=> $b } map { _readyAt($_) } @queue;
		Slim::Utils::Timers::setTimer(undef, $soonest, \&_wake);
		return;
	}

	@queue = grep { $_ != $job } @queue;
	_start($job);
}

sub _wake { _next() }

# Are live streams using enough of the connection that background downloads should wait?
# Uses the measured download capacity; if that isn't known yet, doesn't wait.
sub _busy {
	my $capacity = hosts()->capacity or return;

	my $streaming = 0;
	for my $client (Slim::Player::Client::clients()) {
		next unless Slim::Player::Source::playmode($client) eq 'play';
		my $song = $client->controller->playingSong or next;
		my $handler = $song->currentTrackHandler or next;
		next unless $handler->isRemote;              # cached episodes are local: they don't count

		$streaming += ($song->bitrate || 320_000) / 8;    # bytes/s; assume 320 kbps if unknown
	}

	return if $streaming <= STREAM_SHARE * $capacity;

	return sprintf('live streams are using %.0f%% of the connection', 100 * $streaming / $capacity);
}

sub _start {
	my $job = shift;

	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $ep    = $job->{episode};

	my $path = $cache->pathFor($ep->{feedTitle} || 'Unsorted', $ep);

	my $ready = $cache->prepare($path);
	if (!$ready->{ok}) {
		_finish($job, undef, sprintf("Can't download \"%s\": %s", _title($job), $ready->{reason}));
		return _next();
	}

	# resume what an earlier attempt left, if we know which version of the file it was
	my $previous = $cache->lookup($job->{key}) || {};
	my @args = ('--url', $ep->{url}, '--out', $path, '--status', "$path.status",
		'--user-agent', Slim::Utils::Misc::userAgentString());
	push @args, '--etag', $previous->{etag} if $previous->{etag};
	push @args, '--last-modified', $previous->{lastModified} if $previous->{lastModified};
	push @args, '--expected', $previous->{expectedSize} if $previous->{expectedSize};

	unlink "$path.status";

	my $proc = Proc::Background->new($^X, $script, @args);
	if (!$proc) {
		_finish($job, undef, sprintf("Can't start the download of \"%s\"", _title($job)));
		return _next();
	}

	$cache->record($path, $ep, state => 'partial');

	@$job{qw(path proc startedAt)} = ($path, $proc, time());
	$active = $job;

	Plugins::PodcastCache::Status->info(sprintf('Downloading "%s"%s%s', _title($job),
		$job->{priority} == BACKFILL ? ' (back catalogue)' : $job->{priority} == FIRST ? ' (start of series)' : '',
		$previous->{etag} || $previous->{lastModified} ? ' (resuming)' : ''));

	Slim::Utils::Timers::setTimer(undef, time() + POLL_SECS, \&_poll);
}

sub _poll {
	my $job = $active or return;

	my $status = _readStatus("$job->{path}.status");
	$job->{progress} = $status if $status;

	if ($job->{proc}->alive) {
		Slim::Utils::Timers::setTimer(undef, time() + POLL_SECS, \&_poll);
		return;
	}

	$active = undef;

	# the process has ended and we've read how: the status file has served its purpose
	unlink "$job->{path}.status";

	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $title = _title($job);
	my %validators = map { $_ => $status->{$_} } grep { $status && defined $status->{$_} } qw(etag lastModified);

	# learn which server actually served it (a redirect to a CDN, say)
	my $host = Plugins::PodcastCache::Hosts->hostOf($job->{episode}->{url});
	if ($status && $status->{finalUrl}) {
		my $via = Plugins::PodcastCache::Hosts->hostOf($status->{finalUrl});
		hosts()->state->{via}->{$host} = $via if $via && $via ne $host;
	}

	if ($job->{preempted} && !($status && $status->{state} eq 'complete')) {
		# stopped to make way for a play request: not the server's fault; resume later
		my %partial = (state => 'partial', %validators);
		$partial{expectedSize} = $status->{expected} if $status && $status->{expected};
		$cache->record($job->{path}, $job->{episode}, %partial);

		delete @$job{qw(proc path progress preempted)};
		push @queue, $job;
		Plugins::PodcastCache::Status->info(sprintf('Paused "%s" to download an episode being played', $title));
	}
	elsif ($status && $status->{state} eq 'complete') {
		$cache->record($job->{path}, $job->{episode}, state => 'complete',
			expectedSize => $status->{expected} || -s $job->{path}, %validators);

		my $secs = $status->{finishedAt} - $status->{startedAt};
		hosts()->finished($_, ok => 1, bytes => $status->{bytes}, secs => $secs) for _hostsFor($job);
		_saveHosts();

		my $extra = join ', ', grep { $_ }
			($status->{resumes} ? "$status->{resumes} resume" . ($status->{resumes} > 1 ? 's' : '') : ''),
			($status->{restarts} ? "$status->{restarts} restart" . ($status->{restarts} > 1 ? 's' : '') : '');

		Plugins::PodcastCache::Status->count('downloaded');
		Plugins::PodcastCache::Status->info(sprintf('Downloaded "%s" (%.1f MB in %ds%s)',
			$title, ($status->{bytes} || 0) / 1024**2, int($secs + 0.5), $extra ? "; $extra" : ''));

		_finish($job, $job->{path});

		# a new episode may push an old one past the feed's limit
		Plugins::PodcastCache::Retention->schedule($job->{episode}->{feedUrl});
	}
	else {
		my $error = $status ? ($status->{error} || 'failed') : 'the download process ended without a status';

		hosts()->finished($_, code => ($status && $status->{httpCode}) || 0,
			retryAfter => $status && $status->{retryAfter}) for _hostsFor($job);
		_saveHosts();

		my $code = $status && $status->{httpCode} || 0;

		if ($GONE{$code}) {
			# the file isn't there: nothing to resume, and no point asking again for a while
			$lmsCache->set('podcastcache-gone-' . $job->{episode}->{url}, time(), GONE_DAYS . 'days');
			my $entry = $cache->lookup($job->{key});
			$cache->remove($entry) if $entry;

			Plugins::PodcastCache::Status->warn(sprintf('Skipping "%s": no longer on the server (HTTP %s); will look again in %d days',
				$title, $code, GONE_DAYS));
			# tell anyone waiting (a play request then streams, and gets the same answer)
			for my $cb (@{ $job->{callbacks} }) {
				eval { $cb->(undef, "no longer on the server (HTTP $code)") };
				$log->error("Download callback failed: $@") if $@;
			}
			return _next();
		}

		# keep what we got, and the validators, so the next attempt can resume
		my %partial = (state => 'partial', %validators);
		$partial{expectedSize} = $status->{expected} if $status && $status->{expected};
		$cache->record($job->{path}, $job->{episode}, %partial);

		if ($status && $status->{throttled} && $job->{priority} != PLAY && ++$job->{throttles} <= MAX_THROTTLES) {
			# the server asked us to slow down: try again when it's ready (Hosts knows when)
			delete @$job{qw(proc path progress)};
			push @queue, $job;
			Plugins::PodcastCache::Status->warn(sprintf('"%s": %s; will try again after %s',
				$title, $error, _hhmm(_readyAt($job))));
		}
		else {
			_finish($job, undef, "Download of \"$title\" failed: $error");
		}
	}

	_next();
}

sub _finish {
	my ($job, $path, $error) = @_;

	Plugins::PodcastCache::Status->error($error) if $error;

	for my $cb (@{ $job->{callbacks} }) {
		eval { $cb->($path, $error) };
		$log->error("Download callback failed: $@") if $@;
	}
}

sub _title {
	my $job = shift;
	return $job->{episode}->{title} || $job->{episode}->{url};
}

sub _hhmm {
	my @t = localtime(shift);
	return sprintf('%02d:%02d', $t[2], $t[1]);
}

sub _readStatus {
	my $file = shift;

	open(my $fh, '<', $file) or return;
	local $/;
	my $data = eval { decode_json(<$fh>) };
	close $fh;

	return ref $data eq 'HASH' ? $data : undef;
}

# drop queued back-catalogue jobs for feeds that no longer want them
sub dropUnwanted {
	my $class = shift;

	my $before = @queue;
	@queue = grep {
		$_->{priority} == PLAY || $_->{priority} == NEWEST
			|| Plugins::PodcastCache::Plugin::backfillFor($_->{episode}->{feedUrl})
	} @queue;

	my $dropped = $before - @queue;
	Plugins::PodcastCache::Status->info("Dropped $dropped queued back-catalogue download" . ($dropped == 1 ? '' : 's')) if $dropped;
}

# forget what we know about a server (its gap, cooldown and statistics)
sub resetHost {
	my ($class, $host) = @_;
	my $known = delete hosts()->state->{hosts}->{ lc $host };
	delete hosts()->state->{via}->{ lc $host };
	_saveHosts();
	_next();
	return $known ? 1 : 0;
}

# the politeness preset changed
sub setPreset {
	my ($class, $preset) = @_;
	hosts()->preset($preset);
	_saveHosts();
	_next();
}

# is this episode's file known to be gone from its server?
sub isGone {
	my ($class, $url) = @_;
	return $lmsCache->get("podcastcache-gone-$url") ? 1 : 0;
}

# where an episode is in the queue: { state => 'downloading', pct => N } or
# { state => 'queued' }, or nothing
sub stateFor {
	my ($class, $url) = @_;

	if ($active && $active->{episode}->{url} eq $url) {
		my $p = $active->{progress};
		return { state => 'downloading', pct => $p && $p->{expected} ? int(100 * ($p->{bytes} || 0) / $p->{expected}) : undef };
	}

	return { state => 'queued' } if grep { $_->{episode}->{url} eq $url } @queue;
	return;
}

# for the settings page
sub summary {
	my $act = $active ? {
		title    => _title($active),
		bytes    => $active->{progress} ? $active->{progress}->{bytes} : 0,
		expected => $active->{progress} ? $active->{progress}->{expected} : undef,
		attempt  => $active->{progress} ? $active->{progress}->{attempt} : 1,
		resumes  => $active->{progress} ? $active->{progress}->{resumes} : 0,
		secs     => time() - $active->{startedAt},
	} : undef;

	my %count;
	$count{ $_->{priority} }++ for @queue;

	my ($soonest) = sort { $a <=> $b } map { _readyAt($_) } grep { $_->{priority} != PLAY } @queue;

	my $cap = hosts()->capacity;

	return {
		active   => $act,
		queued   => scalar @queue,
		newest   => $count{+NEWEST} || 0,
		startOfSeries => $count{+FIRST} || 0,
		backfill => $count{+BACKFILL} || 0,
		paused   => $paused,
		nextAt   => $soonest && $soonest > time() ? _hhmm($soonest) : undef,
		capacity => $cap ? sprintf('%.1f MB/s', $cap / 1024**2) : undef,
		hosts    => [ map {
			my $h = $_;
			+{    # '+': a hash, not a block
				%$h,
				gapText   => _duration($h->{gap}),
				coolText  => $h->{coolUntil} ? _hhmm($h->{coolUntil}) : undef,
				speedText => $h->{bps} ? sprintf('%.1f MB/s', $h->{bps} / 1024**2) : undef,
			}
		} @{ hosts()->summary } ],
	};
}

sub _duration {
	my $s = shift || 0;
	return $s >= 3600 ? sprintf('%.1f h', $s / 3600) : $s >= 60 ? sprintf('%d min', $s / 60) : "${s}s";
}

# stop everything, e.g. when LMS shuts down; partial downloads stay for next time
sub stop {
	@queue = ();

	if ($active) {
		$active->{proc}->die;
		$active = undef;
	}

	Slim::Utils::Timers::killTimers(undef, \&_poll);
	Slim::Utils::Timers::killTimers(undef, \&_wake);
	_saveHosts() if $hosts;
}

1;
