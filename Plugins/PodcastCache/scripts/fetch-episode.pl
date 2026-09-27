#!/usr/bin/perl
#
# fetch-episode.pl - download one podcast episode to disk, resuming if the server cuts it off.
#
#   fetch-episode.pl --url URL --out PATH [--status FILE]
#                    [--etag ETAG] [--last-modified DATE] [--expected BYTES]
#                    [--attempts N] [--backoff SECS] [--stall-time SECS] [--curl PATH]
#
# Downloads to PATH.part with curl and renames it to PATH only once its size matches what
# the server said. If the connection closes early (curl exit 18), stalls, or fails, it
# resumes with Range + If-Range, so a resumed download is only ever joined to the same
# version of the file. If the file changed upstream (exit 33), or there is nothing safe to
# resume against, it starts again from zero.
#
# --attempts caps attempts that make no progress; any attempt that adds bytes resets the
# count, so a server that cuts every connection after a few MB still gets there.
#
# Writes progress as JSON to --status (default PATH.status) about once a second.
# Exit 0 when PATH is complete, 1 when it gave up (the reason is in the status file).
#
# Core Perl only, and no LMS modules: LMS runs this as a separate process.

use strict;
use warnings;

use Getopt::Long;
use JSON::PP;
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

my %opt = (
	attempts          => 8,     # consecutive attempts without progress
	'max-total'       => 200,   # hard cap on attempts of any kind
	backoff           => 2,     # seconds, doubled per failed attempt, capped at 60
	'stall-time'      => 60,    # abort (and resume) if under 1 KB/s for this long
	'connect-timeout' => 30,
	curl              => 'curl',
);

GetOptions(\%opt, qw(url=s out=s status=s etag=s last-modified=s expected=i attempts=i
	max-total=i backoff=f stall-time=i connect-timeout=i curl=s user-agent=s))
	or die "usage: $0 --url URL --out PATH [options]\n";

die "--url and --out are required\n" unless $opt{url} && $opt{out};

my $out     = $opt{out};
my $part    = "$out.part";
my $headers = "$out.headers";
my $errfile = "$out.curlerr";
my $status  = $opt{status} || "$out.status";

my $json = JSON::PP->new->canonical;

my %state = (
	state        => 'downloading',
	url          => $opt{url},
	path         => $out,
	etag         => $opt{etag},
	lastModified => $opt{'last-modified'},
	expected     => $opt{expected},
	attempt      => 0,
	resumes      => 0,
	restarts     => 0,
	startedAt    => time(),
);

my $curlPid;

$SIG{TERM} = $SIG{INT} = sub {
	kill 'TERM', $curlPid if $curlPid;
	finish(0, 'stopped');
};

# a partial download can only be resumed against a validator from the same version
if (-e $part && !validator()) {
	unlink $part;
}

my $stuck = 0;    # consecutive attempts without progress

while (1) {
	$state{attempt}++;

	my $before = -s $part || 0;
	my $resume = $before && validator() ? 1 : 0;
	unlink $part unless $resume;
	$state{resumes}++ if $resume;

	my $result = runCurl($resume);
	my $size   = -s $part || 0;

	# learn the size and validators from the response
	my $resp = $result->{response};
	if ($resp->{code}) {
		$state{httpCode} = $resp->{code};

		if ($resp->{code} == 200) {
			$state{expected} = $resp->{length} if defined $resp->{length};
			$state{etag} = $resp->{etag};
			$state{lastModified} = $resp->{lastModified};
		}
		elsif ($resp->{code} == 206 && $resp->{total}) {
			$state{expected} = $resp->{total};
		}
	}

	my $exit = $result->{exit};
	$state{curlExit} = $exit;

	# done?
	if ($state{expected} && $size == $state{expected}) {
		finish(1);
	}
	if ($exit == 0 && !$state{expected} && $size) {
		finish(1);    # no Content-Length (chunked): curl saw the proper end
	}

	my ($retry, $delay, $error) = decide($exit, $resp->{code} || 0, $size, $result->{error});
	$state{error} = $error;

	finish(0, $error) unless $retry;

	$stuck = $size > $before ? 0 : $stuck + 1;

	if ($stuck >= $opt{attempts}) {
		finish(0, "gave up after $stuck attempts without progress: $error");
	}
	if ($state{attempt} >= $opt{'max-total'}) {
		finish(0, "gave up after $state{attempt} attempts: $error");
	}

	writeStatus();
	sleep($delay) if $delay;
}

# What to do after an attempt: (retry?, delay, reason)
sub decide {
	my ($exit, $code, $size, $curlError) = @_;

	my $backoff = $opt{backoff} * 2 ** ($stuck > 0 ? $stuck : 0);
	$backoff = 60 if $backoff > 60;

	# the server closed the connection early: resume straight away
	return (1, 0, 'connection closed early') if $exit == 18;

	# asked to resume, but got the whole file back: it changed upstream (or the server
	# doesn't do ranges). Start again from zero.
	if ($exit == 33) {
		restart();
		return (1, 0, 'file changed on the server, or no range support; starting again');
	}

	if ($exit == 0 && $state{expected} && $size != $state{expected}) {
		restart() if $size > $state{expected};
		return (1, $backoff, "size $size does not match $state{expected}");
	}

	if ($exit == 22) {    # HTTP error, from --fail
		if ($code == 416) {    # range not satisfiable: our partial doesn't fit this file
			restart();
			return (1, 0, 'range not satisfiable; starting again');
		}
		return (1, $backoff, "HTTP $code") if $code == 408 || $code == 429 || $code >= 500;
		return (0, 0, 'HTTP ' . ($code || 'error'));
	}

	# network trouble worth retrying: resolve, connect, timeout or stall, TLS, empty
	# reply, send/receive errors, HTTP/2 stream errors
	my %transient = map { $_ => 1 } (5, 6, 7, 16, 28, 35, 52, 55, 56, 92);
	return (1, $backoff, $curlError || "curl exit $exit") if $transient{$exit};

	# anything else (bad url, can't write the file, ...) won't fix itself
	return (0, 0, $curlError || "curl exit $exit");
}

sub restart {
	unlink $part;
	delete @state{qw(expected etag lastModified)};
	$state{restarts}++;
}

sub validator {
	return $state{etag} if $state{etag} && $state{etag} !~ m{^W/};   # If-Range needs a strong ETag
	return $state{lastModified};
}

sub runCurl {
	my $resume = shift;

	my @cmd = ($opt{curl}, '-sS', '-L', '--fail',
		'--connect-timeout', $opt{'connect-timeout'},
		'--speed-limit', 1024, '--speed-time', $opt{'stall-time'},
		'-D', $headers, '-o', $part);
	push @cmd, '-A', $opt{'user-agent'} if $opt{'user-agent'};
	push @cmd, '-C', '-', '-H', 'If-Range: ' . validator() if $resume;
	push @cmd, '--', $opt{url};

	unlink $headers, $errfile;

	$curlPid = fork();
	die "fork: $!" unless defined $curlPid;

	if (!$curlPid) {
		open(STDOUT, '>', '/dev/null');
		open(STDERR, '>', $errfile);
		exec @cmd or exit 127;
	}

	# report progress while curl runs
	my $last = 0;
	while (1) {
		my $done = waitpid($curlPid, WNOHANG);
		last if $done == $curlPid;

		if (time() - $last >= 1) {
			$state{bytes} = -s $part || 0;
			my $resp = parseHeaders();
			$state{expected} ||= $resp->{code} && $resp->{code} == 206 ? $resp->{total} : $resp->{length};
			writeStatus();
			$last = time();
		}
		sleep(0.2);
	}

	my $exit = $? & 127 ? 128 + ($? & 127) : $? >> 8;
	$curlPid = undef;

	my $error = '';
	if (open(my $fh, '<', $errfile)) {
		local $/;
		$error = <$fh> // '';
		close $fh;
		$error =~ s/\s+$//;
	}

	return { exit => $exit, response => parseHeaders(), error => $error };
}

# the final response's status and headers (after any redirects)
sub parseHeaders {
	open(my $fh, '<', $headers) or return {};
	local $/;
	my $text = <$fh> // '';
	close $fh;

	my @blocks = grep { /^HTTP\// } split /\r?\n\r?\n/, $text;
	my $block = $blocks[-1] or return {};

	my ($code) = $block =~ m{^HTTP/\S+\s+(\d{3})};
	my %h;
	for my $line (split /\r?\n/, $block) {
		my ($k, $v) = $line =~ /^([^:\s]+):\s*(.*?)\s*$/ or next;
		$h{lc $k} = $v;
	}

	my ($total) = ($h{'content-range'} || '') =~ m{/(\d+)$};

	return {
		code         => $code,
		length       => $h{'content-length'},
		total        => $total,
		etag         => $h{etag},
		lastModified => $h{'last-modified'},
	};
}

sub writeStatus {
	$state{bytes} = -e $out && $state{state} eq 'complete' ? -s $out : (-s $part || 0);
	$state{updatedAt} = time();

	my $tmp = "$status.tmp";
	open(my $fh, '>', $tmp) or return;
	print $fh $json->encode(\%state);
	close $fh;
	rename $tmp, $status;
}

sub finish {
	my ($ok, $error) = @_;

	if ($ok) {
		rename($part, $out) or do { $ok = 0; $error = "cannot rename $part: $!" };
	}

	$state{state} = $ok ? 'complete' : 'failed';
	$state{error} = $ok ? undef : $error;
	$state{finishedAt} = time();

	writeStatus();
	unlink $headers, $errfile;

	exit($ok ? 0 : 1);
}
