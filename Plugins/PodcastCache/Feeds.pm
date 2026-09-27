package Plugins::PodcastCache::Feeds;

# Remembers what the built-in parser saw about each episode (its feed, title, date, type),
# keyed by enclosure url. At play time the handler only has the url, but a download needs
# these for its folder, file name and retention.
#
# Wraps Slim::Plugin::Podcast::Parser::parse rather than copying the parser, so upstream
# changes to it still apply. LMS's RSS parsing drops <guid>, so episodes are identified by
# their enclosure url.

use strict;

use Date::Parse qw(str2time);

use Slim::Plugin::Podcast::Parser;
use Slim::Utils::Cache;
use Slim::Utils::Log;

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

		eval { _remember($_[1], $feed) };
		$log->error("Couldn't record episode details: $@") if $@;

		return $feed;
	};
}

sub _remember {
	my ($http, $feed) = @_;

	my $feedUrl = $http->params->{params}->{url};
	return unless ref $feed eq 'HASH';

	for my $item (@{ $feed->{items} || [] }) {
		# the parser has already wrapped the url; an episode with a resume position has
		# 'play' instead of an enclosure
		my $wrappedUrl = ($item->{enclosure} && $item->{enclosure}->{url}) || $item->{play} or next;
		my ($url) = Slim::Plugin::Podcast::Plugin::unwrapUrl($wrappedUrl) or next;

		my $type = $item->{enclosure} ? lc($item->{enclosure}->{type} || '') : '';

		$cache->set("podcastcache-ep-$url", {
			url       => $url,
			title     => $item->{title} || $item->{name},
			pubdate   => $item->{pubdate} ? str2time($item->{pubdate}) : undef,
			feedUrl   => $feedUrl,
			feedTitle => $feed->{title},
			ext       => $extForType{$type},
		}, '90days');
	}
}

# What we know about an episode, by enclosure url; at least { url }.
sub episode {
	my ($class, $url) = @_;
	my $episode = $cache->get("podcastcache-ep-$url");
	return ref $episode eq 'HASH' ? { %$episode } : { url => $url };
}

1;
