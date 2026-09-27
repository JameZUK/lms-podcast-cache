#!/usr/bin/perl
# Tests for Plugins::PodcastCache::Hosts (adaptive per-host politeness), with a fake clock.
# Runs without LMS:  prove -I. tests/hosts.t

use strict;
use warnings;

use Test::More;

use Plugins::PodcastCache::Hosts;

my $H = 'Plugins::PodcastCache::Hosts';

my $now = 1_000_000;
sub fresh { $H->new(now => sub { $now }, @_) }

subtest 'host names' => sub {
	is $H->hostOf('https://Audio.Example.com/ep/1.mp3'), 'audio.example.com', 'lower-cased';
	is $H->hostOf('http://cdn.example.net:8080/x'), 'cdn.example.net', 'port dropped';
	is $H->hostOf('https://user@host.example/x'), 'host.example', 'userinfo dropped';
	is $H->hostOf('not a url'), '', 'nonsense';
};

subtest 'a new host starts at the preset gap, and clean downloads shorten it' => sub {
	my $h = fresh();
	is $h->readyAt('a.example'), 120, 'never used: ready (gap counts from time 0)';

	$h->finished('a.example', ok => 1, bytes => 80e6, secs => 2);
	is $h->readyAt('a.example'), $now + 102, 'gap shrinks by 15% after a clean download';

	$h->finished('a.example', ok => 1, bytes => 80e6, secs => 2) for 1 .. 30;
	is $h->state->{hosts}->{'a.example'}->{gap}, 30, 'but never below the preset minimum';

	my $g = fresh(preset => 'gentle');
	$g->finished('b.example', ok => 1, bytes => 1, secs => 1) for 1 .. 50;
	is $g->state->{hosts}->{'b.example'}->{gap}, 120, 'gentle: minimum 2 minutes';

	is fresh(preset => 'nonsense')->preset, 'normal', 'unknown preset: normal';
};

subtest '429 with Retry-After: wait exactly that long, and double the gap' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 429, retryAfter => 600);
	is $h->coolingUntil('a.example'), $now + 600, 'cooling for Retry-After';
	is $h->state->{hosts}->{'a.example'}->{gap}, 240, 'gap doubled';
	like $h->summary->[0]->{reason}, qr/HTTP 429, as the server asked/, 'says why';
	ok $h->readyAt('a.example') >= $now + 600, 'not ready before the cooldown ends';
};

subtest '503 without Retry-After: escalating backoff, reset by success' => sub {
	my $h = fresh();
	my @waits;
	for (1 .. 7) {
		$h->finished('a.example', code => 503);
		push @waits, $h->coolingUntil('a.example') - $now;
	}
	is_deeply \@waits, [60, 300, 900, 3600, 21600, 86400, 86400], '1 min, 5, 15, 1 h, 6 h, 24 h, then stays at 24 h';
	is $h->state->{hosts}->{'a.example'}->{gap}, 120 * 2**7, 'gap doubled each time (120 s x 2^7)';
	$h->finished('a.example', code => 503);
	is $h->state->{hosts}->{'a.example'}->{gap}, 21600, 'and capped at 6 h';

	$h->finished('a.example', ok => 1, bytes => 1e6, secs => 1);
	$h->finished('a.example', code => 503);
	is $h->coolingUntil('a.example') - $now, 60, 'after a success, the backoff starts again from 1 min';
};

subtest '403 twice: treated as blocked for a day' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 403);
	is $h->coolingUntil('a.example'), 0, 'once: could be one bad link';
	$h->finished('a.example', code => 403);
	is $h->coolingUntil('a.example'), $now + 86400, 'twice: 24 h';
	like $h->summary->[0]->{reason}, qr/probably blocked/, 'says why';
};

subtest 'network failures: slow down, back off after three' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 0) for 1 .. 2;
	is $h->coolingUntil('a.example'), 0, 'two failures: no cooldown yet';
	ok $h->state->{hosts}->{'a.example'}->{gap} > 120, 'but the gap grew';
	$h->finished('a.example', code => 0);
	is $h->coolingUntil('a.example'), $now + 60, 'third: back off';
};

subtest 'a download much slower than usual lengthens the gap' => sub {
	my $h = fresh();
	$h->finished('a.example', ok => 1, bytes => 80e6, secs => 2) for 1 .. 3;    # ~40 MB/s
	my $gap = $h->state->{hosts}->{'a.example'}->{gap};
	$h->finished('a.example', ok => 1, bytes => 80e6, secs => 80);               # 1 MB/s
	is $h->state->{hosts}->{'a.example'}->{gap}, $gap * 1.5, 'gap x1.5';
	like $h->summary->[0]->{reason}, qr/slower than usual/, 'says why';

	$h->finished('b.example', ok => 1, bytes => 500_000, secs => 5);
	$h->finished('b.example', ok => 1, bytes => 500_000, secs => 50);
	unlike $h->summary->[1]->{reason} // '', qr/slower/, 'small files are too noisy to judge';
};

subtest 'a missing file (404) is not held against the server' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 404) for 1 .. 10;
	is $h->coolingUntil('a.example'), 0, 'no cooldown after ten dead links';
	is $h->state->{hosts}->{'a.example'}->{gap}, 120, 'gap unchanged';
	is $h->summary->[0]->{failed}, 10, 'but they are counted';
	$h->finished('a.example', code => 410);
	is $h->coolingUntil('a.example'), 0, '410 too';
};

subtest 'hosts are independent' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 429);
	ok $h->coolingUntil('a.example'), 'a is cooling';
	is $h->coolingUntil('b.example'), 0, 'b is not';
};

subtest 'connection capacity: the fastest recent download' => sub {
	my $h = fresh();
	is $h->capacity, undef, 'unknown at first';
	$h->finished('a.example', ok => 1, bytes => 40e6, secs => 1);
	is $h->capacity, 40e6, '40 MB/s';
	$h->finished('b.example', ok => 1, bytes => 10e6, secs => 1);
	is $h->capacity, 40e6 * 0.98, 'a slower download does not lower it much';
};

subtest 'asking about a host does not remember it' => sub {
	my $h = fresh();
	$h->readyAt('x.example');
	$h->coolingUntil('x.example');
	is scalar(@{ $h->summary }), 0, 'no entry created by reading';
};

subtest 'state survives a restart' => sub {
	my $h = fresh();
	$h->finished('a.example', code => 429, retryAfter => 3600);
	my $again = fresh(state => $h->state);
	is $again->coolingUntil('a.example'), $now + 3600, 'cooldown restored';
};

done_testing;
