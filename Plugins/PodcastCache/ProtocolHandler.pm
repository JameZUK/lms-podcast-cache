package Plugins::PodcastCache::ProtocolHandler;

# podcast:// handler. A cached episode is scanned from its local file, then handed to
# FileHandler through Song's currentTrackHandler hook, so it is read from disk and never
# direct-streamed. An episode that isn't cached is downloaded first (it jumps the queue),
# then played from disk; if that fails, or takes longer than the playWait pref, it is
# streamed as the built-in does, and the download carries on for next time.
#
# The track keeps its podcast:// URL, so the built-in's title, cover and resume position
# (podcast-$url) all carry on working.

use base qw(Slim::Plugin::Podcast::ProtocolHandler);

use strict;

use Time::HiRes;

use Slim::Formats;
use Slim::Music::Info;
use Slim::Schema::RemoteTrack;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::PodcastCache::Downloader;
use Plugins::PodcastCache::Feeds;
use Plugins::PodcastCache::FileHandler;
use Plugins::PodcastCache::Status;

my $prefs = preferences('plugin.podcastcache');

# audio properties to take from the local file; title and cover stay the feed's
my @fileTags = qw(SECS BITRATE VBR_SCALE OFFSET SIZE RATE SAMPLESIZE CHANNELS BLOCKALIGN);

sub cachedPath {
	my ($class, $httpUrl) = @_;

	return unless $httpUrl;
	return Plugins::PodcastCache::Plugin::cache()->completePath($httpUrl);
}

sub scanUrl {
	my ($class, $url, $args) = @_;

	my ($httpUrl) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url);

	# title of the clean url, without any {from=N}, as the built-in does
	my $title = Slim::Music::Info::getCurrentTitle($args->{client}, Slim::Plugin::Podcast::Plugin::wrapUrl($httpUrl));

	if (my $path = $class->cachedPath($httpUrl)) {
		return $class->_playFile($url, $args, $path, $title);
	}

	my $wait = $prefs->get('playWait');

	my $done;
	my $stream = sub {
		my $why = shift;
		return if $done++;

		Plugins::PodcastCache::Status->count('streamed');
		Plugins::PodcastCache::Status->info("Streaming \"$title\" ($why)");
		$class->SUPER::scanUrl($url, $args);
	};

	my $episode = Plugins::PodcastCache::Feeds->episode($httpUrl);
	$episode->{title} ||= $title;

	Plugins::PodcastCache::Downloader->fetch($episode, front => 1, cb => sub {
		my ($path, $error) = @_;
		return if $done;    # already streaming: the download is for next time

		return $stream->('the download failed') unless $path;

		$done = 1;
		$class->_playFile($url, $args, $path, $title);
	});

	# on a slow connection, don't keep the listener waiting for a whole episode
	if (!$done) {
		my $why = $wait ? "not downloaded within ${wait}s; still downloading for next time"
		                : 'downloading for next time';
		Slim::Utils::Timers::setTimer(undef, time() + $wait, sub { $stream->($why) });
	}
}

# play a cached episode from $path
sub _playFile {
	my ($class, $url, $args, $path, $title) = @_;

	my ($httpUrl, $startTime) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url);
	my $song = $args->{song};

	my $tags = Slim::Formats->readTags($path);

	if (!$tags->{SECS}) {
		Plugins::PodcastCache::Status->count('streamed');
		Plugins::PodcastCache::Status->error("Can't read $path; streaming \"$title\" instead");
		return $class->SUPER::scanUrl($url, $args);
	}

	# same seek handling as the built-in
	$song->seekdata({ startTime => $startTime }) if $startTime;

	my %attributes = map { $_ => $tags->{$_} } grep { defined $tags->{$_} } @fileTags;
	$attributes{CT} = Slim::Music::Info::typeFromPath($path);

	# Must be a different object from the podcast:// track Song already holds, or
	# Song won't call currentTrackHandler. The built-in gets one the same way, by
	# scanning the http url and renaming the result.
	my $track = Slim::Schema::RemoteTrack->updateOrCreate($httpUrl, \%attributes);
	$track->title($title);
	$track->cover(0);
	$track->url(Slim::Plugin::Podcast::Plugin::wrapUrl($httpUrl));

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
