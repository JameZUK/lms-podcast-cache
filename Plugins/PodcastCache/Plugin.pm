package Plugins::PodcastCache::Plugin;

# Replaces only the playback half of the built-in Podcasts plugin: episodes that are
# cached on disk are played from the file instead of streamed from the origin.
# The built-in keeps its feeds, menus, parser and resume positions.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

# Load the built-in handler first: it registers itself for podcast:// when compiled,
# and the last registration wins.
use Slim::Plugin::Podcast::ProtocolHandler;
use Plugins::PodcastCache::Cache;
use Plugins::PodcastCache::Downloader;
use Plugins::PodcastCache::Feeds;
use Plugins::PodcastCache::Prefetch;
use Plugins::PodcastCache::ProtocolHandler;
use Plugins::PodcastCache::Retention;
use Plugins::PodcastCache::Status;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.podcastcache',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_PODCASTCACHE',
});

my $prefs = preferences('plugin.podcastcache');

$prefs->init({
	defaultKeep => 3,      # a number of newest episodes, 'all', or 'current' (only what's playing)
	feedKeep    => {},     # feed url => same, overriding defaultKeep
	playWait    => 30,     # seconds to wait for a download before streaming instead
	prefetch    => 1,      # download new episodes ahead of time
	prefetchHours => 6,    # how often to check the feeds
	quietStart  => '',     # hours (0-23) when no background downloads start; '' = off
	quietEnd    => '',
});

$prefs->setValidate({ validator => sub { $_[1] =~ m{^/.} } }, 'cacheRoot');
$prefs->setValidate({ validator => sub { $_[1] =~ /^(?:all|current|[1-9]\d{0,2})$/ } }, 'defaultKeep');
$prefs->setValidate({ validator => 'intlimit', low => 0, high => 600 }, 'playWait');
$prefs->setValidate({ validator => 'intlimit', low => 1, high => 168 }, 'prefetchHours');
$prefs->setValidate({ validator => sub { $_[1] =~ /^(?:|[01]?\d|2[0-3])$/ } }, 'quietStart', 'quietEnd');

$prefs->setChange(sub { Plugins::PodcastCache::Prefetch->start }, 'prefetchHours', 'prefetch');

my $cache;

# the cache is re-read from disk if its folder changes
$prefs->setChange(sub { undef $cache }, 'cacheRoot');

sub initPlugin {
	my $class = shift;

	# default: a hidden folder in the first music folder, which the scanner skips
	$prefs->init({ cacheRoot => _defaultCacheRoot() });

	Slim::Player::ProtocolHandlers->registerHandler('podcast', 'Plugins::PodcastCache::ProtocolHandler');

	# learn each episode's feed, title and date as the built-in parser reads feeds
	Plugins::PodcastCache::Feeds->init;

	# apply the keep settings once LMS has settled (players connected, playlists restored)
	Plugins::PodcastCache::Retention->scheduleAll(60);

	# check the feeds for new episodes, soon and then every prefetchHours
	Plugins::PodcastCache::Prefetch->start;

	if (main::WEBUI) {
		require Plugins::PodcastCache::Settings;
		Plugins::PodcastCache::Settings->new;
	}

	# podcastcache fetch <url> [title]: download an episode into the cache
	Slim::Control::Request::addDispatch(['podcastcache', 'fetch', '_url', '_title'], [0, 0, 0, \&_cliFetch]);

	# podcastcache refresh: check all feeds for new episodes now
	Slim::Control::Request::addDispatch(['podcastcache', 'refresh'], [0, 0, 0, sub {
		Plugins::PodcastCache::Prefetch->checkNow;
		$_[0]->setStatusDone;
	}]);

	Plugins::PodcastCache::Status->info('Started: handling podcast:// playback, cache at ' . $prefs->get('cacheRoot'));

	if (!Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Podcast::Plugin')) {
		Plugins::PodcastCache::Status->error('The built-in Podcasts plugin is disabled; enable it for feeds and menus');
	}

	$class->SUPER::initPlugin(@_);
}

sub shutdownPlugin {
	Plugins::PodcastCache::Prefetch->stop;
	Plugins::PodcastCache::Downloader->stop;
}

sub _cliFetch {
	my $request = shift;

	my $url = $request->getParam('_url') || '';
	($url) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url) if $url =~ m{^podcast://};

	if ($url !~ m{^https?://}) {
		$request->setStatusBadParams;
		return;
	}

	Plugins::PodcastCache::Downloader->fetch({
		url       => $url,
		title     => $request->getParam('_title'),
		feedTitle => 'Unsorted',
	});

	$request->setStatusDone;
}

sub _defaultCacheRoot {
	my ($dir) = @{ Slim::Utils::Misc::getAudioDirs() || [] };
	$dir ||= preferences('server')->get('cachedir');
	return "$dir/.podcast-cache";
}

# the on-disk cache, indexed from its sidecars on first use
sub cache {
	return $cache ||= do {
		my $c = Plugins::PodcastCache::Cache->new(root => $prefs->get('cacheRoot'));
		my $count = $c->rebuild;
		Plugins::PodcastCache::Status->info("Cache index: $count episodes in " . $c->root);
		$c;
	};
}

# retention for a feed: a number of newest episodes, 'all', or 'current'
sub keepFor {
	my $feedUrl = shift;
	my $keep = ($prefs->get('feedKeep') || {})->{$feedUrl};
	return defined $keep ? $keep : $prefs->get('defaultKeep');
}

sub keepLabel {
	my $keep = shift;
	return 'all episodes' if $keep eq 'all';
	return 'only the episode playing' if $keep eq 'current';
	return $keep == 1 ? 'newest episode' : "newest $keep";
}

1;
