package Plugins::PodcastCache::FileHandler;

# Plays a cached episode from disk. Slim::Player::Protocols::File does the work
# (seeking, no direct streaming, isRemote 0); this only maps the podcast:// URL to
# the cached file and passes the podcast lifecycle calls back to our handler.

use base qw(Slim::Player::Protocols::File);

use strict;

sub pathFromFileURL {
	my ($class, $url) = @_;

	my ($httpUrl) = Slim::Plugin::Podcast::Plugin::unwrapUrl($url);
	return Plugins::PodcastCache::ProtocolHandler->cachedPath($httpUrl);
}

# resume position: podcast:// urls carry {from=N}, turned into seekdata here
sub getNextTrack { shift; Plugins::PodcastCache::ProtocolHandler->getNextTrack(@_) }

# save resume position, update recently played
sub onStop   { shift; Plugins::PodcastCache::ProtocolHandler->onStop(@_) }
sub onStream { shift; Plugins::PodcastCache::ProtocolHandler->onStream(@_) }

1;
