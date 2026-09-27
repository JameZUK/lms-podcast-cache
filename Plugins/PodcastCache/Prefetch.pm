package Plugins::PodcastCache::Prefetch;

# Downloads new episodes ahead of time, so they play from disk the first time.
#
# Every prefetchHours, reads each subscribed feed through the built-in parser, one at a
# time. Whenever a feed is read (by this timer, or by someone browsing it), Feeds.pm calls
# queue(), which queues what isn't cached yet, behind anything waiting to play:
#   keep = N         -> the newest N (retention then keeps the same N)
#   keep = 'all'     -> the newest ALL_COUNT; and with "download the back catalogue" on,
#                       then the first few episodes (start of series), then all the rest,
#                       newest first
#   keep = 'current' -> nothing
# Downloader spaces these out per server (Hosts.pm) and puts anything being played first.
# Nothing is queued during the optional quiet hours; playing an episode still downloads it.

use strict;

use Slim::Formats::XML;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::PodcastCache::Downloader;
use Plugins::PodcastCache::Plan;
use Plugins::PodcastCache::Status;

use constant ALL_COUNT   => 3;
use constant FIRST_CHECK => 120;    # seconds after start-up
use constant QUIET_RETRY => 1800;   # re-check this often during quiet hours

my $log   = logger('plugin.podcastcache');
my $prefs = preferences('plugin.podcastcache');

my ($lastCheck, $nextCheck, $checking);

sub start {
	my $class = shift;
	$class->_schedule(FIRST_CHECK);
}

# check the feeds shortly, e.g. because the download settings changed
sub soon {
	my $class = shift;
	$class->_schedule(10);
}

sub stop {
	my $class = shift;
	Slim::Utils::Timers::killTimers($class, \&_check);
	$nextCheck = undef;
}

sub _schedule {
	my ($class, $secs) = @_;

	Slim::Utils::Timers::killTimers($class, \&_check);
	$nextCheck = time() + $secs;
	Slim::Utils::Timers::setTimer($class, $nextCheck, \&_check);
}

# check every subscribed feed now, even in quiet hours (the CLI's "podcastcache refresh")
sub checkNow {
	my $class = shift;
	$class->_check('force');
}

sub _check {
	my ($class, $force) = @_;
	$force = 0 unless defined $force && $force eq 'force';    # timers pass other arguments

	if (!$prefs->get('prefetch') && !$force) {
		return $class->_schedule($prefs->get('prefetchHours') * 3600);
	}

	if ($class->quiet && !$force) {
		return $class->_schedule(QUIET_RETRY);
	}

	$class->_schedule($prefs->get('prefetchHours') * 3600);

	return if $checking;

	my $ready = Plugins::PodcastCache::Plugin::cache()->writable;
	if (!$ready->{ok}) {
		Plugins::PodcastCache::Status->warn("Not checking for new episodes: $ready->{reason}");
		return;
	}

	my @feeds = map { $_->{value} } @{ preferences('plugin.podcast')->get('feeds') || [] };
	return unless @feeds;

	$lastCheck = time();
	$checking = $force ? 'force' : 1;
	Plugins::PodcastCache::Status->info(sprintf('Checking %d podcast%s for new episodes', scalar @feeds, @feeds == 1 ? '' : 's'));

	# one feed at a time, as the built-in does, to go easy on small servers
	my $next;
	$next = sub {
		my $url = shift @feeds;
		if (!$url) {
			$checking = 0;
			undef $next;
			return;
		}

		Slim::Formats::XML->getFeedAsync(
			sub { $next->() },    # the parser (and so Feeds.pm, and queue()) has done the work
			sub {
				Plugins::PodcastCache::Status->warn("Couldn't read the feed $url: $_[0]");
				$next->();
			},
			{ parser => 'Slim::Plugin::Podcast::Parser', url => $url, timeout => 30 },
		);
	};
	$next->();
}

# Called with a feed's episodes whenever the built-in parser reads it.
sub queue {
	my ($class, $feedUrl, $episodes) = @_;

	return unless $feedUrl && $episodes && @$episodes;
	return unless $prefs->get('prefetch') || ($checking || '') eq 'force';
	return if $class->quiet && ($checking || '') ne 'force';

	my $keep = Plugins::PodcastCache::Plugin::keepFor($feedUrl);
	return if $keep eq 'current';

	my $cache = Plugins::PodcastCache::Plugin::cache();

	my @planned = Plugins::PodcastCache::Plan::plan($episodes,
		keep     => $keep,
		backfill => Plugins::PodcastCache::Plugin::backfillFor($feedUrl),
		first    => Plugins::PodcastCache::Plugin::firstFor($feedUrl),
		allCount => ALL_COUNT,
	);

	# not cached yet, and not known to be gone from the server
	my @missing = grep { !$cache->completePath($_->[1]->{url}) && !Plugins::PodcastCache::Downloader->isGone($_->[1]->{url}) } @planned;
	return unless @missing;

	return unless $cache->writable->{ok};    # _check reports this; don't repeat it per feed

	my %count;
	for (@missing) {
		my ($priority, $ep, $order) = @$_;
		$count{$priority}++;
		Plugins::PodcastCache::Downloader->fetch($ep, priority => $priority, order => $order);
	}

	my $newest = $count{ Plugins::PodcastCache::Plan::NEWEST() } || 0;
	my $older  = @missing - $newest;
	Plugins::PodcastCache::Status->info(sprintf('Queued %s of "%s"',
		join(' and ', grep { $_ }
			($newest ? sprintf('%d new episode%s', $newest, $newest == 1 ? '' : 's') : ''),
			($older ? sprintf('%d from the back catalogue', $older) : '')),
		$missing[0]->[1]->{feedTitle} || $feedUrl));
}

sub quiet {
	my ($start, $end) = ($prefs->get('quietStart'), $prefs->get('quietEnd'));
	return 0 unless defined $start && defined $end && length $start && length $end && $start != $end;

	my $hour = (localtime)[2];
	return $start < $end ? ($hour >= $start && $hour < $end) : ($hour >= $start || $hour < $end);
}

# for the settings page
sub summary {
	return {
		enabled  => $prefs->get('prefetch') ? 1 : 0,
		checking => $checking ? 1 : 0,
		quiet    => __PACKAGE__->quiet ? 1 : 0,
		# not 'last'/'next': Template Toolkit treats those as list methods when empty
		lastCheck => $lastCheck ? _hhmm($lastCheck) : undef,
		nextCheck => $nextCheck ? _hhmm($nextCheck) : undef,
	};
}

sub _hhmm {
	my @t = localtime(shift);
	return sprintf('%02d:%02d', $t[2], $t[1]);
}

1;
