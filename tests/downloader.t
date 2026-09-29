#!/usr/bin/perl
# Tests for scripts/fetch-episode.pl against a local HTTP server that misbehaves on purpose:
# it cuts connections mid-body, changes the file between requests, stalls, and errors.
# Needs curl. Runs without LMS:  prove -I. tests/downloader.t

use strict;
use warnings;

use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP;
use Test::More;

my $script = 'Plugins/PodcastCache/scripts/fetch-episode.pl';

plan skip_all => 'curl not found' unless grep { -x "$_/curl" } split /:/, $ENV{PATH};

my $dir = tempdir(CLEANUP => 1);

# ---------------------------------------------------------------------------
# The server

sub content {
	my ($tag, $len) = @_;
	my $s = join '', map { sprintf("%s%07d\n", $tag, $_) } 0 .. int($len / 9) + 1;
	return substr($s, 0, $len);
}

my $A  = content('A', 200_000);
my $B  = content('B', 150_000);
my $LM = 'Wed, 01 Jan 2025 00:00:00 GMT';

my $log = "$dir/requests.log";

my $listen = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 20,
	ReuseAddr => 1, Proto => 'tcp') or die "listen: $!";
my $port = $listen->sockport;

my $serverPid = fork();
die "fork: $!" unless defined $serverPid;

if (!$serverPid) {
	my %count;
	while (my $c = $listen->accept) {
		handle($c, \%count);
		close $c;
	}
	exit 0;
}
close $listen;

END { kill 'TERM', $serverPid if $serverPid }

sub handle {
	my ($c, $count) = @_;

	my $request = <$c> // return;
	my ($path) = $request =~ m{^\S+\s+(\S+)};
	my %h;
	while (my $line = <$c>) {
		last if $line =~ /^\r?\n$/;
		my ($k, $v) = $line =~ /^([^:]+):\s*(.*?)\r?\n$/ or next;
		$h{lc $k} = $v;
	}

	my $n = ++$count->{$path};

	open(my $lf, '>>', $log);
	printf $lf "%s n=%d range=%s ifrange=%s\n", $path, $n, $h{range} // '-', $h{'if-range'} // '-';
	close $lf;

	my %strong = (content => $A, etag => '"etag-a"', lm => $LM);

	if    ($path eq '/ok')             { serve($c, \%h, %strong) }
	elsif ($path eq '/truncate-once')  { serve($c, \%h, %strong, cut => $n == 1 ? 60_000 : undef) }
	elsif ($path eq '/truncate-every') { serve($c, \%h, %strong, cut => 40_000) }
	elsif ($path eq '/changed') {
		$n == 1 ? serve($c, \%h, %strong, cut => 50_000)
		        : serve($c, \%h, content => $B, etag => '"etag-b"', lm => 'Thu, 02 Jan 2025 00:00:00 GMT');
	}
	elsif ($path eq '/noetag-truncate') { serve($c, \%h, content => $A, cut => $n == 1 ? 60_000 : undef) }
	elsif ($path eq '/weak-etag') { serve($c, \%h, content => $A, etag => 'W/"weak"', lm => $LM, cut => $n == 1 ? 60_000 : undef) }
	elsif ($path eq '/404')       { status($c, 404) }
	elsif ($path eq '/500')       { status($c, 500) }
	elsif ($path eq '/503-once')  { $n == 1 ? status($c, 503) : serve($c, \%h, %strong) }
	elsif ($path eq '/429-secs')  { status($c, 429, 'Retry-After: 120') }
	elsif ($path eq '/429-date')  { status($c, 429, 'Retry-After: ' . httpDate(time() + 3600)) }
	elsif ($path eq '/redirect')  { print $c "HTTP/1.1 302 Found\r\nLocation: /ok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
	elsif ($path eq '/chunked')   { chunked($c) }
	elsif ($path eq '/stall')     { serve($c, \%h, %strong, $n == 1 ? (stallAfter => 30_000) : ()) }
	elsif ($path eq '/slow')      { serve($c, \%h, %strong, $n == 1 ? (stallAfter => 50_000) : ()) }
	elsif ($path eq '/ep_[192k]-1.mp3') { serve($c, \%h, %strong) }
	else                          { status($c, 404) }
}

sub serve {
	my ($c, $h, %s) = @_;

	my $content = $s{content};
	my $len = length $content;
	my ($start, $code) = (0, 200);

	if (($h->{range} || '') =~ /^bytes=(\d+)-$/) {
		my $from = $1;
		my $ifRange = $h->{'if-range'};
		my $match = !defined $ifRange
			|| (defined $s{etag} && $s{etag} !~ m{^W/} && $ifRange eq $s{etag})
			|| (defined $s{lm} && $ifRange eq $s{lm});

		if ($match) {
			if ($from >= $len) {
				print $c "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$len\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
				return;
			}
			($start, $code) = ($from, 206);
		}
	}

	my $body = substr($content, $start);

	my $head = "HTTP/1.1 $code " . ($code == 206 ? 'Partial Content' : 'OK') . "\r\n"
		. "Content-Length: " . length($body) . "\r\n"
		. "Accept-Ranges: bytes\r\n"
		. ($code == 206 ? "Content-Range: bytes $start-" . ($len - 1) . "/$len\r\n" : '')
		. (defined $s{etag} ? "ETag: $s{etag}\r\n" : '')
		. (defined $s{lm} ? "Last-Modified: $s{lm}\r\n" : '')
		. "Connection: close\r\n\r\n";

	print $c $head;

	if ($s{stallAfter}) {
		print $c substr($body, 0, $s{stallAfter});
		$c->flush;
		sleep 4;
		return;
	}

	$body = substr($body, 0, $s{cut}) if defined $s{cut} && $s{cut} < length $body;
	print $c $body;
}

sub status {
	my ($c, $code, $extra) = @_;
	print $c "HTTP/1.1 $code Error\r\nContent-Length: 5\r\n" . ($extra ? "$extra\r\n" : '') . "Connection: close\r\n\r\nerror";
}

sub httpDate {
	my @t = gmtime(shift);
	return sprintf('%s, %02d %s %04d %02d:%02d:%02d GMT', (qw(Sun Mon Tue Wed Thu Fri Sat))[$t[6]], $t[3],
		(qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec))[$t[4]], $t[5] + 1900, @t[2, 1, 0]);
}

sub chunked {
	my $c = shift;
	print $c "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
	for (my $i = 0; $i < length $A; $i += 30_000) {
		my $chunk = substr($A, $i, 30_000);
		printf $c "%x\r\n%s\r\n", length $chunk, $chunk;
	}
	print $c "0\r\n\r\n";
}

# ---------------------------------------------------------------------------
# Running the script

my $runs = 0;

sub fetch {
	my ($path, @extra) = @_;

	my $out = "$dir/out" . ++$runs . '.mp3';
	my $pre = ref $extra[0] eq 'CODE' ? shift @extra : undef;
	$pre->($out) if $pre;

	system($^X, $script, '--url', "http://127.0.0.1:$port$path", '--out', $out,
		'--backoff', '0.05', @extra);
	my $exit = $? >> 8;

	my $status = eval {
		open(my $fh, '<', "$out.status") or die;
		local $/;
		decode_json(<$fh>);
	} || {};

	my $data;
	if (open(my $fh, '<', $out)) { local $/; $data = <$fh>; close $fh }

	return ($exit, $status, $out, $data);
}

sub requests {
	my $path = shift;
	open(my $fh, '<', $log) or return ();
	return grep { /^\Q$path\E / } <$fh>;
}

sub same {
	my ($got, $want, $name) = @_;
	ok(defined $got && $got eq $want, $name) or diag('got ' . (defined $got ? length($got) . ' bytes' : 'no file'));
}

# ---------------------------------------------------------------------------

subtest 'plain download' => sub {
	my ($exit, $st, $out, $data) = fetch('/ok');
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	ok !-e "$out.part", 'no .part left';
	ok !-e "$out.headers" && !-e "$out.curlerr", 'temp files cleaned up';
	is $st->{state}, 'complete', 'status: complete';
	is $st->{bytes}, 200_000, 'status: bytes';
	is $st->{expected}, 200_000, 'status: expected';
	is $st->{etag}, '"etag-a"', 'status: etag, for later resumes';
	is $st->{resumes}, 0, 'no resumes';
};

subtest 'cut off once, resumed' => sub {
	my ($exit, $st, undef, $data) = fetch('/truncate-once');
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	is $st->{resumes}, 1, 'one resume';
	my @r = requests('/truncate-once');
	like $r[1], qr/range=bytes=60000- ifrange="etag-a"/, 'resumed from the cut, guarded by the ETag';
};

subtest 'cut off every time: keeps going while it makes progress' => sub {
	my ($exit, $st, undef, $data) = fetch('/truncate-every', '--attempts', 2);
	is $exit, 0, 'exit 0, even with --attempts 2';
	same $data, $A, 'complete and identical';
	is $st->{resumes}, 4, 'four resumes (40 KB at a time)';
};

subtest 'file changed between attempts: starts again' => sub {
	my ($exit, $st, undef, $data) = fetch('/changed');
	is $exit, 0, 'exit 0';
	same $data, $B, 'got the new version, not a splice of both';
	is $st->{restarts}, 1, 'one restart';
	my @r = requests('/changed');
	like $r[1], qr/ifrange="etag-a"/, 'tried to resume with the old ETag';
	like $r[2], qr/range=- /, 'then fetched the whole file again';
};

subtest 'no ETag or Last-Modified: never resumes blind' => sub {
	my ($exit, $st, undef, $data) = fetch('/noetag-truncate');
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	my @r = requests('/noetag-truncate');
	ok !(grep { !/range=- / } @r), 'no Range request was made';
};

subtest 'weak ETag: resumes on Last-Modified instead' => sub {
	my ($exit, $st, undef, $data) = fetch('/weak-etag');
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	my @r = requests('/weak-etag');
	like $r[1], qr/ifrange=\Q$LM\E/, 'If-Range used Last-Modified';
};

subtest 'resume a .part left by an earlier run' => sub {
	my ($exit, $st, undef, $data) = fetch('/ok', sub {
		open(my $fh, '>', "$_[0].part"); print $fh substr($A, 0, 70_000); close $fh;
	}, '--etag', '"etag-a"', '--expected', 200_000);
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	my @r = requests('/ok');
	like $r[-1], qr/range=bytes=70000- ifrange="etag-a"/, 'picked up where it left off';
};

subtest 'a .part that is already complete' => sub {
	my ($exit, $st, undef, $data) = fetch('/ok', sub {
		open(my $fh, '>', "$_[0].part"); print $fh $A; close $fh;
	}, '--etag', '"etag-a"', '--expected', 200_000);
	is $exit, 0, 'exit 0';
	same $data, $A, 'renamed into place';
	my @r = requests('/ok');
	like $r[-1], qr/range=bytes=200000- /, 'asked for the rest (the server says 416: nothing left)';
};

subtest 'a stale .part with no validator is discarded' => sub {
	my ($exit, $st, undef, $data) = fetch('/ok', sub {
		open(my $fh, '>', "$_[0].part"); print $fh 'junk' x 1000; close $fh;
	});
	is $exit, 0, 'exit 0';
	same $data, $A, 'fresh download, no junk';
};

subtest 'stalled connection: aborted and resumed' => sub {
	my ($exit, $st, undef, $data) = fetch('/stall', '--stall-time', 1);
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
	my @r = requests('/stall');
	like $r[1], qr/range=bytes=\d+- ifrange="etag-a"/, 'resumed after the stall';
};

subtest 'stopped half-way (e.g. LMS shutting down): the status keeps what is needed to resume' => sub {
	my $out = "$dir/killed.mp3";
	my $pid = fork();
	if (!$pid) { exec $^X, $script, '--url', "http://127.0.0.1:$port/slow", '--out', $out; exit 127 }
	sleep 2;
	kill 'TERM', $pid;
	waitpid($pid, 0);

	my $st = do { open(my $fh, '<', "$out.status"); local $/; decode_json(<$fh>) };
	is $st->{state}, 'failed', 'status: failed';
	is $st->{error}, 'stopped', 'status: stopped';
	is $st->{etag}, '"etag-a"', 'status: ETag already recorded';
	ok -s "$out.part", 'partial kept (' . (-s "$out.part" || 0) . ' bytes)';

	system($^X, $script, '--url', "http://127.0.0.1:$port/slow", '--out', $out, '--etag', $st->{etag}, '--expected', 200_000);
	is $? >> 8, 0, 'the next run completes';
	my @r = requests('/slow');
	like $r[-1], qr/range=bytes=\d+- ifrange="etag-a"/, 'by resuming, not starting again';
	my $data = do { open(my $fh, '<', $out); local $/; <$fh> };
	same $data, $A, 'complete and identical';
};

subtest 'redirect' => sub {
	my ($exit, $st, undef, $data) = fetch('/redirect');
	is $exit, 0, 'exit 0';
	same $data, $A, 'followed to the file';
	is $st->{etag}, '"etag-a"', 'validators from the final response';
	like $st->{finalUrl} // '', qr{/ok$}, 'records the final url after redirects';
};

subtest 'chunked, no Content-Length' => sub {
	my ($exit, $st, undef, $data) = fetch('/chunked');
	is $exit, 0, 'exit 0';
	same $data, $A, 'complete and identical';
};

subtest '503: the server is asking us to slow down, so stop and report' => sub {
	my ($exit, $st) = fetch('/503-once');
	is $exit, 1, 'exit 1';
	ok $st->{throttled}, 'status: throttled';
	is $st->{httpCode}, 503, 'status: HTTP 503';
	is scalar(requests('/503-once')), 1, 'no retry: the caller decides when to come back';
};

subtest '429 with Retry-After in seconds' => sub {
	my ($exit, $st) = fetch('/429-secs');
	is $exit, 1, 'exit 1';
	ok $st->{throttled}, 'status: throttled';
	is $st->{retryAfter}, 120, 'status: retryAfter 120';
	is scalar(requests('/429-secs')), 1, 'one request';
};

subtest '429 with Retry-After as an HTTP date' => sub {
	my ($exit, $st) = fetch('/429-date');
	ok $st->{retryAfter} >= 3590 && $st->{retryAfter} <= 3600, 'retryAfter about an hour (' . ($st->{retryAfter} // 'undef') . ')';
};

subtest 'square brackets in the URL are taken literally' => sub {
	my ($exit, $st, undef, $data) = fetch('/ep_[192k]-1.mp3');
	is $exit, 0, 'exit 0 (curl would read [192k] as a range without --globoff)';
	same $data, $A, 'complete and identical';
};

subtest 'a problem on our side is flagged as local, not the server\'s fault' => sub {
	my $out = "$dir/local.mp3";
	system($^X, $script, '--url', "htp://127.0.0.1:$port/ok", '--out', $out, '--status', "$out.status");
	is $? >> 8, 1, 'exit 1';
	my $st = do { open(my $fh, '<', "$out.status"); local $/; decode_json(<$fh>) };
	ok $st->{local}, 'status: local';
	ok !$st->{throttled}, 'not throttled';
	ok !$st->{httpCode}, 'no HTTP code';
	like $st->{error}, qr/\S/, 'with a reason: ' . ($st->{error} // '');
};

subtest 'not found: gives up at once' => sub {
	my ($exit, $st, $out) = fetch('/404');
	is $exit, 1, 'exit 1';
	is $st->{state}, 'failed', 'status: failed';
	like $st->{error}, qr/404/, 'says why';
	is scalar(requests('/404')), 1, 'no retries';
	ok !$st->{local}, 'the server said so: not local';
	ok !-e $out && !-e "$out.part", 'nothing left behind';
};

subtest 'server keeps failing: gives up after --attempts' => sub {
	my ($exit, $st) = fetch('/500', '--attempts', 3);
	is $exit, 1, 'exit 1';
	like $st->{error}, qr/gave up after 3 attempts.*500/, 'says why';
	is scalar(requests('/500')), 3, 'three attempts';
};

subtest 'cannot write: gives up at once' => sub {
	my $out = "$dir/no-such-dir/x.mp3";
	system($^X, $script, '--url', "http://127.0.0.1:$port/ok", '--out', $out, '--status', "$dir/nowrite.status");
	is $? >> 8, 1, 'exit 1';
	open(my $fh, '<', "$dir/nowrite.status"); local $/; my $st = decode_json(<$fh>);
	is $st->{state}, 'failed', 'status: failed';
	like $st->{error}, qr/\S/, 'with a reason: ' . ($st->{error} // '');
};

done_testing;
