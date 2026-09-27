package Plugins::PodcastCache::Feeds;

# Remembers what the built-in parser saw about each episode (its feed, title, date, type),
# keyed by enclosure url. At play time the handler only has the url, but a download needs
# these for its folder, file name and retention.
#
# Also labels each episode in the menu with its cache state, on its second line (line2,
# next to the date and duration): [cached], [downloading 42%] or [queued]. Not the title:
# LMS reuses that as the track title in Now Playing and "Recently played".
#
# Wraps Slim::Plugin::Podcast::Parser::parse rather than copying the parser, so upstream
# changes to it still apply. LMS's RSS parsing drops <guid>, so episodes are identified by
# their enclosure url.

use strict;

use Date::Parse qw(str2time);

use Slim::Plugin::Podcast::Parser;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log   = logger('plugin.podcastcache');
my $cache = Slim::Utils::Cache->new;

my %extForType = (
	'audio/mpeg'  => 'mp3', 'audio/mp3'   => 'mp3',
	'audio/mp4'   => 'm4a', 'audio/x-m4a' => 'm4a', 'audio/m4a' => 'm4a',
	'audio/aac'   => 'aac', 'audio/x-aac' => 'aac',
	'audio/ogg'   => 'ogg', 'audio/opus'  => 'opus', 'audio/flac' => 'flac',
);

my $wrapped;

sub init {
	return if $wrapped++;

	my $parse = \&Slim::Plugin::Podcast::Parser::parse;

	no warnings 'redefine';
	*Slim::Plugin::Podcast::Parser::parse = sub {
		my $feed = $parse->(@_);

		eval { _remember($_[1], $feed); _label($_[1], $feed) };
		$log->error("Couldn't record or label episodes: $@") if $@;

		return $feed;
	};
}

sub _remember {
	my ($http, $feed) = @_;

	my $feedUrl = $http->params->{params}->{url};
	return unless ref $feed eq 'HASH';

	my @episodes;

	for my $item (@{ $feed->{items} || [] }) {
		my ($url) = _urlOf($item) or next;

		my $type = $item->{enclosure} ? lc($item->{enclosure}->{type} || '') : '';

		my $episode = {
			url       => $url,
			title     => $item->{title} || $item->{name},
			pubdate   => $item->{pubdate} ? str2time($item->{pubdate}) : undef,
			feedUrl   => $feedUrl,
			feedTitle => $feed->{title},
			ext       => $extForType{$type},
		};

		$cache->set("podcastcache-ep-$url", $episode, '90days');
		push @episodes, $episode;
	}

	Plugins::PodcastCache::Prefetch->queue($feedUrl, \@episodes);
	Plugins::PodcastCache::Retention->schedule($feedUrl);
}

sub _label {
	my ($http, $feed) = @_;

	my $client = $http->params->{params}->{client};
	my $cache  = Plugins::PodcastCache::Plugin::cache();

	for my $item (@{ $feed->{items} || [] }) {
		my ($url) = _urlOf($item) or next;

		my $label;
		if ($cache->completePath($url)) {
			$label = cstring($client, 'PLUGIN_PODCASTCACHE_LABEL_CACHED');
		}
		elsif (my $state = Plugins::PodcastCache::Downloader->stateFor($url)) {
			$label = $state->{state} eq 'queued'
				? cstring($client, 'PLUGIN_PODCASTCACHE_LABEL_QUEUED')
				: cstring($client, 'PLUGIN_PODCASTCACHE_LABEL_DOWNLOADING') . (defined $state->{pct} ? " $state->{pct}%" : '');
		}
		next unless $label;

		$item->{line2} = $item->{line2} ? "$item->{line2} [$label]" : "[$label]";
	}
}

# the enclosure url of a parsed item: the parser has already wrapped it, and an episode
# with a resume position has 'play' instead of an enclosure
sub _urlOf {
	my $item = shift;
	my $wrappedUrl = ($item->{enclosure} && $item->{enclosure}->{url}) || $item->{play} or return;
	return Slim::Plugin::Podcast::Plugin::unwrapUrl($wrappedUrl);
}

# What we know about an episode, by enclosure url; at least { url }.
sub episode {
	my ($class, $url) = @_;
	my $episode = $cache->get("podcastcache-ep-$url");
	return ref $episode eq 'HASH' ? { %$episode } : { url => $url };
}

1;
