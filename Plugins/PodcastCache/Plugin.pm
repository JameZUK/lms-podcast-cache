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
use Plugins::PodcastCache::ProtocolHandler;
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
});

$prefs->setValidate({ validator => sub { $_[1] =~ m{^/.} } }, 'cacheRoot');
$prefs->setValidate({ validator => sub { $_[1] =~ /^(?:all|current|[1-9]\d{0,2})$/ } }, 'defaultKeep');

my $cache;

# the cache is re-read from disk if its folder changes
$prefs->setChange(sub { undef $cache }, 'cacheRoot');

sub initPlugin {
	my $class = shift;

	# default: a hidden folder in the first music folder, which the scanner skips
	$prefs->init({ cacheRoot => _defaultCacheRoot() });

	Slim::Player::ProtocolHandlers->registerHandler('podcast', 'Plugins::PodcastCache::ProtocolHandler');

	if (main::WEBUI) {
		require Plugins::PodcastCache::Settings;
		Plugins::PodcastCache::Settings->new;
	}

	Plugins::PodcastCache::Status->info('Started: handling podcast:// playback, cache at ' . $prefs->get('cacheRoot'));

	if (!Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Podcast::Plugin')) {
		Plugins::PodcastCache::Status->error('The built-in Podcasts plugin is disabled; enable it for feeds and menus');
	}

	$class->SUPER::initPlugin(@_);
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
