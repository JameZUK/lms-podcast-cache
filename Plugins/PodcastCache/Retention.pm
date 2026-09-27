package Plugins::PodcastCache::Retention;

# Deletes cached episodes a feed's "keep" setting no longer allows, newest by pubdate
# kept first (Cache::prune does the sorting and deleting). Never deletes:
#  - a player's current episode while it is playing or paused,
#  - anything queued after it,
#  - an episode with a saved resume position (part-listened): the built-in keeps those
#    for 30 days, so it survives until then.
# Episodes earlier in a playlist, or a current one that has been stopped, may go:
# LMS keeps them in the playlist, and otherwise "keep only the episode playing" could
# never delete the one you just finished.

use strict;

use Scalar::Util qw(blessed);

use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::PodcastCache::Status;

use constant DELAY => 5;    # seconds; lets a player's state settle after a stop or a download

my $log      = logger('plugin.podcastcache');
my $lmsCache = Slim::Utils::Cache->new;

# prune a feed a few seconds from now
sub schedule {
	my ($class, $feedUrl) = @_;
	return unless $feedUrl;
	Slim::Utils::Timers::setTimer(undef, time() + DELAY, sub { $class->prune($feedUrl) });
}

sub scheduleAll {
	my ($class, $delay) = @_;
	Slim::Utils::Timers::setTimer(undef, time() + ($delay || DELAY), sub { $class->pruneAll });
}

sub pruneAll {
	my $class = shift;

	my %feeds = map { ($_->{feedUrl} || '') => 1 } Plugins::PodcastCache::Plugin::cache()->entries;
	$class->prune($_) for grep { $_ } sort keys %feeds;
}

sub prune {
	my ($class, $feedUrl) = @_;
	return unless $feedUrl;

	my $keep = Plugins::PodcastCache::Plugin::keepFor($feedUrl);
	return if $keep eq 'all';

	my $inUse = _inUse();

	my @gone = Plugins::PodcastCache::Plugin::cache()->prune($feedUrl, $keep, sub {
		my $entry = shift;
		return 1 if $inUse->{ $entry->{url} };
		return 1 if $lmsCache->get('podcast-' . $entry->{url});    # part-listened
		return 0;
	});

	if (@gone) {
		my $feed = $gone[0]->{feedTitle} || $feedUrl;
		Plugins::PodcastCache::Status->info(sprintf('Removed %d episode%s of "%s" (keeping %s): %s',
			scalar @gone, @gone == 1 ? '' : 's', $feed, Plugins::PodcastCache::Plugin::keepLabel($keep),
			join('; ', map { $_->{title} || $_->{url} } @gone)));
	}

	return @gone;
}

# enclosure urls of the episodes players are using: the current one if playing or
# paused, and everything queued after it
sub _inUse {
	my %urls;

	for my $client (Slim::Player::Client::clients()) {
		my $playlist = Slim::Player::Playlist::playList($client) || [];
		next unless @$playlist;

		my $current = Slim::Player::Source::playingSongIndex($client) || 0;
		my $first = Slim::Player::Source::playmode($client) eq 'stop' ? $current + 1 : $current;

		for my $item (@$playlist[$first .. $#$playlist]) {
			my $url = blessed($item) ? $item->url : $item;
			my ($httpUrl) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url || '') or next;
			$urls{$httpUrl} = 1;
		}
	}

	return \%urls;
}

1;
