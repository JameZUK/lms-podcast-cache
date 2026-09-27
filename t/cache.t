#!/usr/bin/perl
# Tests for Plugins::PodcastCache::Cache. Runs without LMS:  prove -I. t/cache.t

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8 decode_utf8);
use File::Temp qw(tempdir);
use Test::More;

use Plugins::PodcastCache::Cache;

my $C = 'Plugins::PodcastCache::Cache';

binmode Test::More->builder->$_, ':utf8' for qw(output failure_output todo_output);

sub bytes { length encode_utf8(shift) }

sub touch {
	my ($path, $size) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh 'x' x ($size || 10);
	close $fh;
}

# ---------------------------------------------------------------------------
subtest 'sanitise' => sub {
	is $C->sanitise('AC/DC Live'),                'AC-DC Live',                 'slash becomes a dash';
	is $C->sanitise('Episode 5: The Return'),     'Episode 5 - The Return',     'colon-space reads as a dash';
	is $C->sanitise('The Night:Shift Show'),      'The Night-Shift Show',       'bare colon too (SMB mangles it)';
	is $C->sanitise('What? "Why" <now> *|'),      'What Why now',               'Windows-forbidden characters dropped';
	is $C->sanitise("Tab\there\nnewline\x{7}bell"), 'Tab here newline bell',    'control characters become spaces';
	is $C->sanitise('  lots    of   space  '),    'lots of space',              'whitespace collapsed and trimmed';
	is $C->sanitise('.hidden'),                   'hidden',                     'no leading dot';
	is $C->sanitise('...and more'),               'and more',                   'no leading dots';
	is $C->sanitise('ends with dots...'),         'ends with dots',             'no trailing dots';
	is $C->sanitise(''),                          'Untitled',                   'empty';
	is $C->sanitise(undef),                       'Untitled',                   'undef';
	is $C->sanitise('../../etc/passwd'),          '-..-etc-passwd',             'cannot climb out of the folder';
	is $C->sanitise('Café Olé'),                  'Café Olé',                   'unicode kept';
	is $C->sanitise(encode_utf8('Café Olé')),     'Café Olé',                   'UTF-8 bytes accepted';
};

subtest 'length is capped in bytes, not characters' => sub {
	my $ascii = 'a' x 300;
	is bytes($C->sanitise($ascii)), 200, 'ascii capped at 200 bytes';

	# 3 bytes each: 100 characters is 300 bytes
	my $cjk = '音' x 100;
	my $cut = $C->sanitise($cjk);
	ok bytes($cut) <= 200, 'CJK within 200 bytes (' . bytes($cut) . ')';
	is length($cut), 66, 'cut on a character boundary (66 x 3 bytes = 198)';
	ok utf8::is_utf8($cut) && decode_utf8(encode_utf8($cut)) eq $cut, 'still valid text';

	# 4-byte emoji straddling the limit
	my $emoji = ('x' x 198) . '😀😀';
	is $C->sanitise($emoji), 'x' x 198, 'partial 4-byte character dropped';

	my $name = $C->episodeBaseName({ title => 'é' x 300, pubdate => 0 });
	ok bytes("$name [abcdef].mp3.json") <= 255, 'longest derived filename fits in 255 bytes';
};

subtest 'names and keys' => sub {
	# 2026-08-27 12:00 UTC
	is $C->episodeBaseName({ title => 'Vol 605', pubdate => 1787832000 }), '2026-08-27 - Vol 605', 'dated';
	is $C->episodeBaseName({ title => 'Vol 605' }), 'undated - Vol 605', 'no pubdate';

	is $C->extensionFor({ url => 'https://x/a/episode_605.mp3' }),    'mp3', 'from url';
	is $C->extensionFor({ url => 'https://x/a/ep.M4A?token=1#t' }),   'm4a', 'query and case ignored';
	is $C->extensionFor({ url => 'https://x/a/stream.php?id=4' }),    'mp3', 'unknown falls back to mp3';
	is $C->extensionFor({ url => 'https://x/a/ep', ext => 'opus' }),  'opus', 'explicit ext wins';
	is $C->extensionFor({ url => 'https://x/a/ep.exe' }),             'mp3', 'non-audio ext ignored';

	is $C->keyFor({ guid => 'g1', url => 'u1' }), 'g1', 'guid preferred';
	is $C->keyFor({ guid => '',   url => 'u1' }), 'u1', 'url if guid empty';
	is $C->keyFor({ url => 'u1' }),               'u1', 'url if no guid';
};

# ---------------------------------------------------------------------------
subtest 'record, lookup, completeness' => sub {
	my $root  = tempdir(CLEANUP => 1);
	my $cache = $C->new(root => $root);

	my $ep = { guid => 'guid-605', url => 'https://x/episode_605.mp3', title => 'Vol 605',
	           pubdate => 1787832000, feedUrl => 'https://feed', feedTitle => 'The Night:Shift Show' };

	my $path = $cache->pathFor($ep->{feedTitle}, $ep);
	is $path, "$root/The Night-Shift Show/2026-08-27 - Vol 605.mp3", 'path layout';

	ok $cache->prepare($path)->{ok}, 'prepare makes the feed folder';
	ok -d "$root/The Night-Shift Show", 'folder exists';

	touch("$path.part", 5);
	my $e = $cache->record($path, $ep, state => 'partial', expectedSize => 10, etag => '"abc"');
	ok -f "$path.json", 'sidecar written';
	ok !-e "$path.json.tmp", 'no temp file left behind';
	ok !$cache->isComplete($e), 'partial is not complete';
	is $cache->completePath('guid-605'), undef, 'nothing to play yet';

	rename "$path.part", $path;
	touch($path, 10);    # the rest of the download arrived
	$cache->record($path, $ep, state => 'complete', expectedSize => 10);
	is $cache->completePath('guid-605'), $path, 'complete: found by guid';
	is $cache->completePath('https://x/episode_605.mp3'), $path, 'and by enclosure url';
	is $cache->lookup('guid-605')->{etag}, '"abc"', 'earlier fields kept on update';

	touch($path, 9);
	is $cache->completePath('guid-605'), undef, 'size mismatch is not complete';
	touch($path, 10);

	is $cache->pathFor('Some New Title', $ep), $path, 'a known episode keeps its path, even if the feed is renamed';
};

subtest 'two episodes with the same name' => sub {
	my $root  = tempdir(CLEANUP => 1);
	my $cache = $C->new(root => $root);

	my $a = { guid => 'a', url => 'https://x/a.mp3', title => 'Bonus', pubdate => 1787832000 };
	my $b = { guid => 'b', url => 'https://x/b.mp3', title => 'Bonus', pubdate => 1787832000 };

	my $pa = $cache->pathFor('Feed', $a);
	$cache->prepare($pa);
	touch($pa);
	$cache->record($pa, $a, state => 'complete');

	my $pb = $cache->pathFor('Feed', $b);
	isnt $pb, $pa, 'second one gets a different path';
	like $pb, qr{/2026-08-27 - Bonus \[[0-9a-f]{6}\]\.mp3$}, 'with a short hash suffix';
	is $cache->pathFor('Feed', $b), $pb, 'stable';

	# a download in progress also takes the name
	my $c = { guid => 'c', url => 'https://x/c.mp3', title => 'Other', pubdate => 1787832000 };
	my $pc = $cache->pathFor('Feed', $c);
	touch("$pc.part");
	my $d = { guid => 'd', url => 'https://x/d.mp3', title => 'Other', pubdate => 1787832000 };
	isnt $cache->pathFor('Feed', $d), $pc, 'a .part file reserves its name';
};

subtest 'rebuild the index from sidecars' => sub {
	my $root  = tempdir(CLEANUP => 1);
	my $cache = $C->new(root => $root);

	for my $n (1 .. 3) {
		my $ep = { guid => "g$n", url => "https://x/$n.mp3", title => "Ep $n", pubdate => 1787832000 + $n * 86400,
		           feedUrl => 'https://feed', feedTitle => 'Café Feed' };
		my $p = $cache->pathFor($ep->{feedTitle}, $ep);
		$cache->prepare($p);
		touch($p);
		$cache->record($p, $ep, state => 'complete', expectedSize => 10);
	}

	mkdir "$root/.hidden-stuff";
	touch("$root/stray.txt");

	my $fresh = $C->new(root => $root);
	is $fresh->rebuild, 3, 'three episodes found';
	is $fresh->completePath('g2'), $cache->completePath('g2'), 'same path as before (unicode folder)';
	is $fresh->lookup('https://x/3.mp3')->{title}, 'Ep 3', 'url index rebuilt, title intact';
	is scalar($fresh->entries('https://feed')), 3, 'entries by feed';

	is $C->new(root => "$root/missing")->rebuild, 0, 'missing root is simply empty';
};

# ---------------------------------------------------------------------------
subtest 'prune' => sub {
	my $root = tempdir(CLEANUP => 1);

	my $setup = sub {
		my $cache = $C->new(root => $root);
		$cache->rebuild;
		$cache->remove($_) for $cache->entries;

		for my $n (1 .. 5) {
			my $ep = { guid => "g$n", url => "https://x/$n.mp3", title => "Ep $n",
			           pubdate => 1787832000 + $n * 86400, feedUrl => 'https://feed', feedTitle => 'Feed' };
			my $p = $cache->pathFor('Feed', $ep);
			$cache->prepare($p);
			touch($p);
			$cache->record($p, $ep, state => 'complete');
		}

		my $other = { guid => 'o1', url => 'https://y/1.mp3', title => 'Other', pubdate => 1, feedUrl => 'https://other' };
		my $p = $cache->pathFor('Other', $other);
		$cache->prepare($p);
		touch($p);
		$cache->record($p, $other, state => 'complete');

		return $cache;
	};

	my $cache = $setup->();
	my @gone = $cache->prune('https://feed', 3);
	is_deeply [ sort map { $_->{key} } @gone ], [qw(g1 g2)], 'keep 3: the two oldest go';
	ok !-e $_->{path} && !-e "$_->{path}.json", "deleted $_->{key} and its sidecar" for @gone;
	is_deeply [ sort map { $_->{key} } $cache->entries('https://feed') ], [qw(g3 g4 g5)], 'newest three remain';
	ok $cache->completePath('o1'), 'other feeds untouched';

	$cache = $setup->();
	@gone = $cache->prune('https://feed', 'all');
	is scalar(@gone), 0, 'all: nothing deleted';

	$cache = $setup->();
	@gone = $cache->prune('https://feed', 3, sub { $_[0]->{key} eq 'g1' });
	is_deeply [ sort map { $_->{key} } @gone ], [qw(g2)], 'a protected episode survives, even beyond the limit';

	$cache = $setup->();
	@gone = $cache->prune('https://feed', 'current', sub { $_[0]->{key} eq 'g4' });
	is_deeply [ sort map { $_->{key} } $cache->entries('https://feed') ], [qw(g4)], 'current: only the protected (playing) one stays';

	$cache = $setup->();
	@gone = $cache->prune('https://feed', 'current');
	ok !-d "$root/Feed", 'emptied feed folder removed';
	ok -d $root, 'root kept';

	$cache = $setup->();
	my ($partial) = grep { $_->{key} eq 'g1' } $cache->entries;
	$cache->record($partial->{path}, { guid => 'g1' }, state => 'partial');
	@gone = $cache->prune('https://feed', 1);
	is_deeply [ sort map { $_->{key} } @gone ], [qw(g2 g3 g4)], 'partial downloads are left to the downloader';
};

# ---------------------------------------------------------------------------
subtest 'mountpoint guard' => sub {
	my $base = tempdir(CLEANUP => 1);
	my $root = "$base/mnt/music/.podcast-cache";
	mkdir "$base/mnt"; mkdir "$base/mnt/music";

	my $mountinfo = sub {
		my $file = "$base/mountinfo";
		open(my $fh, '>', $file) or die;
		print $fh "22 1 0:21 / / rw,relatime shared:1 - ext4 /dev/sda2 rw\n";
		print $fh "$_\n" for @_;
		close $fh;
		return $file;
	};
	my $autofs = "45 22 0:40 / $base/mnt/music rw,relatime shared:30 - autofs systemd-1 rw,fd=65,direct";
	my $nfs    = "301 45 0:77 / $base/mnt/music rw,relatime shared:150 - nfs4 nas:/export/music rw,vers=4.2";

	my $down = $C->new(root => $root, mountinfo => $mountinfo->($autofs));
	my $st = $down->writable;
	ok !$st->{ok}, 'autofs trigger with nothing behind it: refuse';
	like $st->{reason}, qr/not mounted/, 'says why';
	ok !-d $root, 'and did not create the folder inside the bare mountpoint';

	my $up = $C->new(root => $root, mountinfo => $mountinfo->($autofs, $nfs));
	$st = $up->writable;
	ok $st->{ok}, 'NFS mounted on top of autofs: ok';
	is $st->{mount}->{type}, 'nfs4', 'reports the NFS mount';
	ok -d $root, 'created the cache folder';

	my $local = $C->new(root => "$base/srv/podcasts", mountinfo => $mountinfo->());
	mkdir "$base/srv";
	ok $local->writable->{ok}, 'a plain local folder is fine';

	ok !$C->new(root => 'relative/path')->writable->{ok}, 'relative root refused';

	my $m = $C->mountFor('/mnt/music2/x', $mountinfo->("45 22 0:40 / /mnt/music rw - nfs4 a:/b rw"));
	is $m->{point}, '/', 'prefix match respects path boundaries (/mnt/music2 is not under /mnt/music)';

	$m = $C->mountFor('/mnt/My Disk/x', $mountinfo->('46 22 0:41 / /mnt/My\040Disk rw - ext4 /dev/sdb1 rw'));
	is $m->{point}, '/mnt/My Disk', 'octal escapes in mountinfo decoded';
};

done_testing;
