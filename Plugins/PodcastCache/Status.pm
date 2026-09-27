package Plugins::PodcastCache::Status;

# What the settings page shows: recent activity (kept in memory, newest first) and
# health checks on the handler, the built-in plugin and the cache folder.

use strict;

use File::Spec::Functions qw(catfile);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;

use Plugins::PodcastCache::Cache;

use constant MAX_EVENTS => 100;

my $log   = logger('plugin.podcastcache');
my $prefs = preferences('plugin.podcastcache');

my @events;
my %counts = ( fromCache => 0, streamed => 0, downloaded => 0, errors => 0 );

my %logMethod = ( info => 'info', warn => 'warn', error => 'error' );

sub info  { shift->_event('info',  @_) }
sub warn  { shift->_event('warn',  @_) }
sub error { $counts{errors}++; shift->_event('error', @_) }

sub count { $counts{$_[1]}++ }

sub _event {
	my ($class, $level, $msg) = @_;

	unshift @events, { time => time(), level => $level, msg => $msg };
	splice @events, MAX_EVENTS if @events > MAX_EVENTS;

	my $method = $logMethod{$level};
	$log->$method($msg) if $level ne 'info' || main::INFOLOG;
}

sub summary {
	my $class = shift;

	my $root    = $prefs->get('cacheRoot');
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL('podcast://x') || '';

	# stat first: it triggers the automount if autofs has let it lapse
	my $exists = -d $root;
	my $mount  = Plugins::PodcastCache::Cache->mountFor($root);

	my %status = (
		handler        => $handler,
		handlerActive  => $handler eq 'Plugins::PodcastCache::ProtocolHandler',
		builtinEnabled => Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Podcast::Plugin') ? 1 : 0,
		cacheRoot      => $root,
		rootExists     => $exists ? 1 : 0,
		rootWritable   => ($exists && -w $root) ? 1 : 0,
		mount          => $mount,
		inLibrary      => _inLibrary($root),
		folders        => $exists ? _contents($root) : [],
		counts         => { %counts },
		downloads      => Plugins::PodcastCache::Downloader->summary,
		events         => [ map { { %$_, when => _when($_->{time}) } } @events ],
	);

	my @problems;
	push @problems, 'Playback is not being handled by this plugin' unless $status{handlerActive};
	push @problems, 'The built-in Podcasts plugin is disabled' unless $status{builtinEnabled};
	push @problems, 'The cache folder does not exist' unless $status{rootExists};
	push @problems, 'LMS cannot write to the cache folder' if $status{rootExists} && !$status{rootWritable};
	push @problems, 'Cached episodes would appear in the music library' if $status{inLibrary};
	$status{problems} = \@problems;

	return \%status;
}

# true if the scanner would pick up files under $root: inside a music folder, and no
# path component below it is hidden (the scanner skips names starting with a dot)
sub _inLibrary {
	my $root = shift;

	for my $dir (@{ Slim::Utils::Misc::getAudioDirs() || [] }) {
		next unless $dir && index("$root/", "$dir/") == 0;

		my $below = substr($root, length $dir);
		return 0 if grep { /^\.[^.]/ } split m{/}, $below;
		return 1;
	}

	return 0;
}

# one level of folders under the cache root, with episode counts and sizes
sub _contents {
	my $root = shift;

	opendir(my $dh, $root) or return [];
	my @folders;

	for my $name (sort grep { !/^\./ } readdir $dh) {
		my $dir = catfile($root, $name);
		next unless -d $dir;

		my %folder = ( name => $name, episodes => 0, partial => 0, bytes => 0 );

		if (opendir(my $fdh, $dir)) {
			for my $file (grep { !/^\./ } readdir $fdh) {
				my $size = -s catfile($dir, $file) || 0;

				if ($file =~ /\.part$/) {
					$folder{partial}++;
				}
				elsif ($file =~ /\.(?:mp3|m4a|aac|mp4|ogg|opus|flac)$/i) {
					$folder{episodes}++;
					$folder{bytes} += $size;
				}
			}
			closedir $fdh;
		}

		$folder{size} = _size($folder{bytes});
		push @folders, \%folder;
	}
	closedir $dh;

	return \@folders;
}

sub _size {
	my $bytes = shift;
	return sprintf('%.1f GB', $bytes / 1024**3) if $bytes >= 1024**3;
	return sprintf('%.1f MB', $bytes / 1024**2);
}

sub _when {
	my @t = localtime(shift);
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
}

1;
