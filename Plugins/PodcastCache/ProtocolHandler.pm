package Plugins::PodcastCache::ProtocolHandler;

# podcast:// handler. Uncached episodes behave exactly as the built-in does.
# A cached episode is scanned from its local file, then handed to FileHandler through
# Song's currentTrackHandler hook, so it is read from disk and never direct-streamed.
# The track keeps its podcast:// URL, so the built-in's title, cover and resume
# position (podcast-$url) all carry on working.

use base qw(Slim::Plugin::Podcast::ProtocolHandler);

use strict;

use Time::HiRes;

use Slim::Formats;
use Slim::Music::Info;
use Slim::Schema::RemoteTrack;

use Plugins::PodcastCache::FileHandler;
use Plugins::PodcastCache::Status;

# audio properties to take from the local file; title and cover stay the feed's
my @fileTags = qw(SECS BITRATE VBR_SCALE OFFSET SIZE RATE SAMPLESIZE CHANNELS BLOCKALIGN);

sub cachedPath {
	my ($class, $httpUrl) = @_;

	return unless $httpUrl;
	return Plugins::PodcastCache::Plugin::cache()->completePath($httpUrl);
}

sub scanUrl {
	my ($class, $url, $args) = @_;

	my ($httpUrl, $startTime) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url);
	my $path = $class->cachedPath($httpUrl);

	# title of the clean url, without any {from=N}, as the built-in does
	my $title = Slim::Music::Info::getCurrentTitle($args->{client}, Slim::Plugin::Podcast::Plugin::wrapUrl($httpUrl));

	if (!$path) {
		Plugins::PodcastCache::Status->count('streamed');
		Plugins::PodcastCache::Status->info("Streaming \"$title\" (not cached)");
		return $class->SUPER::scanUrl($url, $args);
	}

	my $song = $args->{song};

	# same clean url and seek handling as the built-in
	$url = Slim::Plugin::Podcast::Plugin::wrapUrl($httpUrl);
	$song->seekdata({ startTime => $startTime }) if $startTime;

	my $tags = Slim::Formats->readTags($path);

	if (!$tags->{SECS}) {
		Plugins::PodcastCache::Status->count('streamed');
		Plugins::PodcastCache::Status->error("Can't read $path; streaming \"$title\" instead");
		return $class->SUPER::scanUrl($url, $args);
	}

	my %attributes = map { $_ => $tags->{$_} } grep { defined $tags->{$_} } @fileTags;
	$attributes{CT} = Slim::Music::Info::typeFromPath($path);

	# Must be a different object from the podcast:// track Song already holds, or
	# Song won't call currentTrackHandler. The built-in gets one the same way, by
	# scanning the http url and renaming the result.
	my $track = Slim::Schema::RemoteTrack->updateOrCreate($httpUrl, \%attributes);
	$track->title($title);
	$track->cover(0);
	$track->url($url);

	Plugins::PodcastCache::Status->count('fromCache');
	Plugins::PodcastCache::Status->info("Playing \"$title\" from cache ($path)" . ($startTime ? " from ${startTime}s" : ''));

	# must update playlist time for webUI to refresh - as the built-in does
	$song->master->currentPlaylistUpdateTime( Time::HiRes::time() );

	$args->{cb}->($track);
}

sub currentTrackHandler {
	my ($class, $song, $track) = @_;

	my ($httpUrl) = Slim::Plugin::Podcast::Plugin::unwrapUrl($track->url);

	return 'Plugins::PodcastCache::FileHandler' if $class->cachedPath($httpUrl);

	return $class->SUPER::currentTrackHandler($song, $track);
}

1;
