package Plugins::PodcastCache::Downloader;

# Downloads episodes into the cache, one at a time, without blocking LMS.
#
# Each download is a separate process running scripts/fetch-episode.pl, which does the
# work (curl, resume on truncation, If-Range, retries). A one-second timer here reads the
# status file it writes, records the result in the cache, and starts the next one.
#
#   Plugins::PodcastCache::Downloader->fetch($episode, cb => sub { my ($path, $error) = @_ }, front => 1);
#
# $episode: { url, guid, title, pubdate, feedUrl, feedTitle } - url is the enclosure url.

use strict;

use File::Basename qw(dirname);
use JSON::PP;
use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Timers;

use Plugins::PodcastCache::Status;

use constant POLL_SECS => 1;

my $log = logger('plugin.podcastcache');

my $script = dirname(__FILE__) . '/scripts/fetch-episode.pl';

my @queue;      # jobs waiting
my $active;     # the job running, if any

# Queue an episode. Calls cb->($path) when it is on disk, or cb->(undef, $error).
# front => 1 puts it at the head of the queue (someone is waiting to play it).
sub fetch {
	my ($class, $episode, %args) = @_;

	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $key   = $cache->keyFor($episode);

	if (my $path = $cache->completePath($key)) {
		$args{cb}->($path) if $args{cb};
		return;
	}

	# already queued or running: just wait for it too
	if (my ($job) = grep { $_->{key} eq $key } grep { defined } $active, @queue) {
		push @{ $job->{callbacks} }, $args{cb} if $args{cb};

		if ($args{front} && $job != ($active || 0)) {
			@queue = ($job, grep { $_ != $job } @queue);
		}
		return;
	}

	my $job = {
		key       => $key,
		episode   => $episode,
		callbacks => [ $args{cb} || () ],
		queuedAt  => time(),
	};

	$args{front} ? unshift(@queue, $job) : push(@queue, $job);
	main::INFOLOG && $log->info("Queued $episode->{url}" . ($args{front} ? ' (to play)' : ''));

	_next();
}

sub _next {
	return if $active || !@queue;

	my $job   = shift @queue;
	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $ep    = $job->{episode};
	my $title = $ep->{title} || $ep->{url};

	my $path = $cache->pathFor($ep->{feedTitle} || 'Unsorted', $ep);

	my $ready = $cache->prepare($path);
	if (!$ready->{ok}) {
		_finish($job, undef, "Can't download \"$title\": $ready->{reason}");
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
		_finish($job, undef, "Can't start the download of \"$title\"");
		return _next();
	}

	$cache->record($path, $ep, state => 'partial');

	@$job{qw(path proc startedAt)} = ($path, $proc, time());
	$active = $job;

	Plugins::PodcastCache::Status->info("Downloading \"$title\"" . ($previous->{etag} || $previous->{lastModified} ? ' (resuming)' : ''));

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

	my $cache = Plugins::PodcastCache::Plugin::cache();
	my $title = $job->{episode}->{title} || $job->{episode}->{url};
	my %validators = map { $_ => $status->{$_} } grep { $status && defined $status->{$_} } qw(etag lastModified);

	if ($status && $status->{state} eq 'complete') {
		$cache->record($job->{path}, $job->{episode}, state => 'complete',
			expectedSize => $status->{expected} || -s $job->{path}, %validators);
		unlink "$job->{path}.status";

		my $secs = int($status->{finishedAt} - $status->{startedAt} + 0.5);
		my $extra = join ', ', grep { $_ }
			($status->{resumes} ? "$status->{resumes} resume" . ($status->{resumes} > 1 ? 's' : '') : ''),
			($status->{restarts} ? "$status->{restarts} restart" . ($status->{restarts} > 1 ? 's' : '') : '');

		Plugins::PodcastCache::Status->count('downloaded');
		Plugins::PodcastCache::Status->info(sprintf('Downloaded "%s" (%.1f MB in %ds%s)',
			$title, ($status->{bytes} || 0) / 1024**2, $secs, $extra ? "; $extra" : ''));

		_finish($job, $job->{path});

		# a new episode may push an old one past the feed's limit
		Plugins::PodcastCache::Retention->schedule($job->{episode}->{feedUrl});
	}
	else {
		my $error = $status ? ($status->{error} || 'failed') : 'the download process ended without a status';

		# keep what we got, and the validators, so the next attempt can resume
		my %partial = (state => 'partial', %validators);
		$partial{expectedSize} = $status->{expected} if $status && $status->{expected};
		$cache->record($job->{path}, $job->{episode}, %partial);

		_finish($job, undef, "Download of \"$title\" failed: $error");
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

sub _readStatus {
	my $file = shift;

	open(my $fh, '<', $file) or return;
	local $/;
	my $data = eval { decode_json(<$fh>) };
	close $fh;

	return ref $data eq 'HASH' ? $data : undef;
}

# for the settings page
sub summary {
	my $active = $active ? {
		title    => $active->{episode}->{title} || $active->{episode}->{url},
		bytes    => $active->{progress} ? $active->{progress}->{bytes} : 0,
		expected => $active->{progress} ? $active->{progress}->{expected} : undef,
		attempt  => $active->{progress} ? $active->{progress}->{attempt} : 1,
		resumes  => $active->{progress} ? $active->{progress}->{resumes} : 0,
		secs     => time() - $active->{startedAt},
	} : undef;

	return {
		active => $active,
		queue  => [ map { $_->{episode}->{title} || $_->{episode}->{url} } @queue ],
	};
}

# stop everything, e.g. when LMS shuts down; partial downloads stay for next time
sub stop {
	@queue = ();

	if ($active) {
		$active->{proc}->die;
		$active = undef;
	}

	Slim::Utils::Timers::killTimers(undef, \&_poll);
}

1;
