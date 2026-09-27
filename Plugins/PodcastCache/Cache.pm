package Plugins::PodcastCache::Cache;

# The on-disk cache: where episodes go, what is there, and what to delete.
#
#   <root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>        the episode
#   <root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>.json   its sidecar
#   <root>/<Feed Title>/<YYYY-MM-DD> - <Episode Title>.<ext>.part   while downloading
#
# Sidecars are the source of truth; the index is rebuilt from them by walking the tree.
# Episodes are identified by their RSS guid, or their enclosure url if they have none.
#
# Deliberately free of Slim:: modules so it can be tested without LMS. Paths it returns
# are UTF-8 bytes, ready for open(), -e and friends.

use strict;

use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8 decode_utf8);
use File::Spec::Functions qw(catfile);
use JSON::PP;

use constant MAX_NAME_BYTES => 200;   # leaves room for " [hash]", ".ext", ".json" within 255

my %AUDIO_EXT = map { $_ => 1 } qw(mp3 m4a aac mp4 ogg oga opus flac wav);

my $json = JSON::PP->new->utf8->canonical->pretty;

sub new {
	my ($class, %args) = @_;

	my $self = bless {
		root      => $args{root},
		mountinfo => $args{mountinfo} || '/proc/self/mountinfo',
		entries   => {},    # key => entry
		byUrl     => {},    # enclosure url => key
	}, $class;

	return $self;
}

sub root { $_[0]->{root} }

# ---------------------------------------------------------------------------
# Mountpoint guard

# The mount holding $path: the longest mountpoint that contains it. On a tie, the later
# entry in mountinfo is the one on top (an NFS mount over its autofs trigger).
sub mountFor {
	my ($class, $path, $mountinfo) = @_;

	open(my $fh, '<', $mountinfo || '/proc/self/mountinfo') or return;

	my $best;
	while (my $line = <$fh>) {
		my ($left, $right) = split / - /, $line, 2;
		next unless $right;

		my $point = (split ' ', $left)[4];
		$point =~ s/\\([0-7]{3})/chr(oct($1))/eg;

		next unless $path eq $point || index($path, $point eq '/' ? '/' : "$point/") == 0;
		next if $best && length($best->{point}) > length($point);

		my ($type, $source) = split ' ', $right;
		$best = { point => $point, type => $type, source => $source };
	}
	close $fh;

	return $best;
}

# Whether it's safe to write under the root: the filesystem is really mounted (not just
# an autofs trigger with nothing behind it), and the root exists or can be made, and is
# writable. Returns { ok => 1 } or { ok => 0, reason => '...' }.
sub writable {
	my $self = shift;
	my $root = $self->{root};

	return { ok => 0, reason => 'no cache folder is set' } unless $root && $root =~ m{^/};

	# touching the path triggers the automount if autofs has let it lapse
	my $exists = -d $root;

	my $mount = $self->mountFor($root, $self->{mountinfo});
	if (!$mount || $mount->{type} eq 'autofs') {
		return { ok => 0, reason => 'the filesystem holding the cache folder is not mounted' };
	}

	if (!$exists) {
		mkdir $root or return { ok => 0, reason => "cannot create the cache folder: $!" };
	}

	return { ok => 0, reason => 'the cache folder is not writable' } unless -w $root;

	return { ok => 1, mount => $mount };
}

# Get ready to download to $path: check the cache is writable, then make its feed folder.
sub prepare {
	my ($self, $path) = @_;

	my $status = $self->writable;
	return $status unless $status->{ok};

	(my $dir = $path) =~ s{/[^/]+$}{};
	if (!-d $dir && !mkdir $dir) {
		return { ok => 0, reason => "cannot create $dir: $!" };
	}

	return $status;
}

# ---------------------------------------------------------------------------
# Names

# One path component, safe on ext4/NFS and on SMB clients browsing a copy of the cache.
# Takes and returns a character string.
sub sanitise {
	my ($class, $name, $maxBytes) = @_;

	$name = '' unless defined $name;

	# accept UTF-8 bytes as well as characters
	if (!utf8::is_utf8($name) && $name =~ /[\x80-\xff]/) {
		my $decoded = $name;
		$name = $decoded if utf8::decode($decoded);
	}

	$name =~ s/\p{Cc}+/ /g;              # control characters, including newlines
	$name =~ s/\s*:\s+/ - /g;            # "Episode 5: Title" -> "Episode 5 - Title"
	$name =~ s{[/\\:]}{-}g;              # path separators, and ':' which SMB mangles
	$name =~ s/[*?"<>|]//g;              # the rest of what Windows forbids
	$name =~ s/\s+/ /g;
	$name =~ s/^[\s.]+//;                # no hidden files, no leading space
	$name =~ s/[\s.]+$//;                # Windows drops trailing dots and spaces

	$name = 'Untitled' unless length $name;

	return _truncateBytes($name, $maxBytes || MAX_NAME_BYTES);
}

# cut a character string so its UTF-8 encoding fits in $max bytes, on a character boundary
sub _truncateBytes {
	my ($name, $max) = @_;

	return $name if length(encode_utf8($name)) <= $max;

	my $bytes = substr(encode_utf8($name), 0, $max);
	my $cut = decode_utf8($bytes, Encode::FB_QUIET);   # drops a trailing partial character
	$cut =~ s/[\s.]+$//;

	return $cut;
}

sub feedDirName {
	my ($class, $feedTitle) = @_;
	return $class->sanitise($feedTitle);
}

# "<YYYY-MM-DD> - <Episode Title>", without extension
sub episodeBaseName {
	my ($class, $episode) = @_;

	my $date = 'undated';
	if (my $t = $episode->{pubdate}) {
		my @d = gmtime($t);
		$date = sprintf('%04d-%02d-%02d', $d[5] + 1900, $d[4] + 1, $d[3]);
	}

	return $class->sanitise("$date - " . (defined $episode->{title} ? $episode->{title} : ''));
}

sub extensionFor {
	my ($class, $episode) = @_;

	my $ext = lc($episode->{ext} || '');
	return $ext if $AUDIO_EXT{$ext};

	my ($path) = ($episode->{url} || '') =~ m{^[a-z]+://[^/]*([^?#]*)}i;
	($ext) = lc($path || '') =~ /\.([a-z0-9]{2,4})$/;

	return $ext && $AUDIO_EXT{$ext} ? $ext : 'mp3';
}

sub keyFor {
	my ($class, $episode) = @_;
	my $guid = $episode->{guid};
	return defined $guid && length $guid ? $guid : $episode->{url};
}

# ---------------------------------------------------------------------------
# Index

sub lookup {
	my ($self, $id) = @_;
	return unless defined $id;

	my $entry = $self->{entries}->{$id};
	$entry ||= $self->{entries}->{ $self->{byUrl}->{$id} } if $self->{byUrl}->{$id};

	return $entry;
}

# the path of a complete, playable episode, or undef
sub completePath {
	my ($self, $id) = @_;

	my $entry = $self->lookup($id) or return;
	return $self->isComplete($entry) ? $entry->{path} : undef;
}

sub isComplete {
	my ($self, $entry) = @_;

	return 0 unless $entry && ($entry->{state} || '') eq 'complete';
	return 0 unless $entry->{path} && $entry->{path} !~ /\.part$/;

	my $size = -s $entry->{path};
	return 0 unless $size;

	return 0 if $entry->{expectedSize} && $size != $entry->{expectedSize};

	return 1;
}

sub entries {
	my ($self, $feedUrl) = @_;
	my @all = values %{ $self->{entries} };
	return defined $feedUrl ? grep { ($_->{feedUrl} || '') eq $feedUrl } @all : @all;
}

# Where a new episode should go (bytes). Reuses the existing path for a known episode,
# and adds a short hash of its key if another episode already has the name.
sub pathFor {
	my ($self, $feedTitle, $episode) = @_;

	my $key = $self->keyFor($episode);
	if (my $entry = $self->lookup($key)) {
		return $entry->{path};
	}

	my $dir  = catfile($self->{root}, encode_utf8($self->feedDirName($feedTitle)));
	my $base = $self->episodeBaseName($episode);
	my $ext  = $self->extensionFor($episode);

	my $path = catfile($dir, encode_utf8("$base.$ext"));

	if ($self->_taken($path, $key)) {
		my $suffix = ' [' . substr(md5_hex(encode_utf8($key)), 0, 6) . ']';
		$path = catfile($dir, encode_utf8("$base$suffix.$ext"));
	}

	return $path;
}

sub _taken {
	my ($self, $path, $key) = @_;

	for my $entry (values %{ $self->{entries} }) {
		return 1 if $entry->{path} eq $path && $entry->{key} ne $key;
	}

	# a file we don't know about (e.g. a sidecar lost), or a download in progress
	return 1 if -e $path || -e "$path.part";

	return 0;
}

# Record an episode: write its sidecar and update the index. $episode carries the feed
# and item details; %state is e.g. (state => 'complete', expectedSize => ..., etag => ...).
sub record {
	my ($self, $path, $episode, %state) = @_;

	my $entry = {
		%{ $self->lookup($self->keyFor($episode)) || {} },
		key       => $self->keyFor($episode),
		(map { $_ => $episode->{$_} } grep { defined $episode->{$_} } qw(guid url title pubdate feedUrl feedTitle)),
		%state,
		path      => $path,
		updatedAt => time(),
	};

	_writeJson("$path.json", { map { $_ => $entry->{$_} } grep { $_ ne 'path' } keys %$entry })
		or return;

	$self->_index($entry);

	return $entry;
}

sub _index {
	my ($self, $entry) = @_;

	$self->{entries}->{ $entry->{key} } = $entry;
	$self->{byUrl}->{ $entry->{url} } = $entry->{key} if $entry->{url};
}

# Delete an episode and its sidecar (and any partial download), and forget it.
sub remove {
	my ($self, $entry) = @_;

	my $path = $entry->{path};
	unlink $path, "$path.json", "$path.part";

	delete $self->{entries}->{ $entry->{key} };
	delete $self->{byUrl}->{ $entry->{url} } if $entry->{url};

	# tidy up a feed folder we emptied
	(my $dir = $path) =~ s{/[^/]+$}{};
	rmdir $dir if $dir ne $self->{root};

	return 1;
}

# Rebuild the index from the sidecars on disk. Returns the number of episodes found.
sub rebuild {
	my $self = shift;

	$self->{entries} = {};
	$self->{byUrl}   = {};

	my $root = $self->{root};
	opendir(my $dh, $root) or return 0;

	for my $feedDir (grep { !/^\./ } readdir $dh) {
		my $dir = catfile($root, $feedDir);
		next unless -d $dir;

		opendir(my $fdh, $dir) or next;

		for my $file (grep { /\.json$/ && !/^\./ } readdir $fdh) {
			my $data = _readJson(catfile($dir, $file)) or next;
			next unless $data->{key};

			(my $media = $file) =~ s/\.json$//;
			$self->_index({ %$data, path => catfile($dir, $media) });
		}

		closedir $fdh;
	}

	closedir $dh;

	return scalar keys %{ $self->{entries} };
}

# ---------------------------------------------------------------------------
# Retention

# Delete a feed's episodes beyond what $keep allows: a number of newest episodes, 'all',
# or 'current' (none, other than protected ones). Newest by pubdate. $protect is called
# with each candidate entry and returns true to keep it regardless (e.g. it is playing).
# Only complete episodes are considered; partial downloads belong to the downloader.
# Returns the entries deleted.
sub prune {
	my ($self, $feedUrl, $keep, $protect) = @_;

	return () if !defined $keep || $keep eq 'all';

	my $limit = $keep eq 'current' ? 0 : $keep;
	return () unless $limit =~ /^\d+$/;

	my @newestFirst = sort {
		($b->{pubdate} || $b->{updatedAt} || 0) <=> ($a->{pubdate} || $a->{updatedAt} || 0)
	} grep { ($_->{state} || '') eq 'complete' } $self->entries($feedUrl);

	my @deleted;
	for my $entry (@newestFirst[$limit .. $#newestFirst]) {
		next if $protect && $protect->($entry);

		$self->remove($entry);
		push @deleted, $entry;
	}

	return @deleted;
}

# ---------------------------------------------------------------------------

sub _writeJson {
	my ($file, $data) = @_;

	# write then rename, so a sidecar is never half-written
	my $tmp = "$file.tmp";
	open(my $fh, '>', $tmp) or return;
	print $fh $json->encode($data);
	close($fh) or return;

	return rename($tmp, $file);
}

sub _readJson {
	my $file = shift;

	open(my $fh, '<', $file) or return;
	local $/;
	my $data = eval { $json->decode(<$fh>) };
	close $fh;

	return ref $data eq 'HASH' ? $data : undef;
}

1;
