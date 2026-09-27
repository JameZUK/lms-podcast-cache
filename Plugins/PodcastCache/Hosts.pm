package Plugins::PodcastCache::Hosts;

# Politeness towards podcast servers, worked out per host from how each one behaves.
#
# Background downloads (prefetch, back catalogue) from one host are spaced by a gap that
# adapts like TCP congestion control: every clean download shortens it a little (down to
# the preset's minimum); any sign of pushback lengthens it sharply (up to MAX_GAP).
#
# Pushback:
#  - HTTP 429 / 503 (and 420, 509): "slow down". Wait for Retry-After if the server sent
#    one, else back off 1 min, 5 min, 15 min, 1 h, 6 h, 24 h as it keeps happening.
#  - HTTP 403 / 401 twice in a row: probably blocked. Leave the host alone for 24 h.
#  - a download much slower than this host's norm: a soft signal; lengthen the gap.
#  - network failures: lengthen the gap; back off after three in a row.
# A clean download clears the streak. A missing file (404, 410, 451) is not pushback: an
# old episode that's gone says nothing about the server, so it's only counted.
#
# It also keeps an estimate of the connection's download capacity (the fastest recent
# downloads), which Downloader uses to decide whether live streams leave room for
# background downloads.
#
# No LMS modules, and the clock is injectable, so it can be tested on its own.

use strict;

use constant MAX_GAP  => 6 * 3600;
use constant BLOCKED  => 24 * 3600;
use constant SLOW     => 0.25;     # a download at under 25% of the host's usual speed is a soft signal

my %PRESETS = (
	gentle => { start => 300, min => 120 },
	normal => { start => 120, min => 30  },
	fast   => { start => 30,  min => 5   },
);

my @BACKOFF = (60, 300, 900, 3600, 6 * 3600, 24 * 3600);

my %THROTTLE = map { $_ => 1 } (420, 429, 503, 509);
my %REFUSED  = map { $_ => 1 } (401, 403);
my %GONE     = map { $_ => 1 } (404, 410, 451);

sub new {
	my ($class, %args) = @_;

	my $self = bless {
		state  => $args{state} || {},
		preset => $PRESETS{ $args{preset} || '' } ? $args{preset} : 'normal',
		now    => $args{now} || sub { time() },
	}, $class;

	$self->{state}->{hosts} ||= {};
	return $self;
}

sub presets { sort keys %PRESETS }

sub preset {
	my ($self, $preset) = @_;
	$self->{preset} = $preset if $preset && $PRESETS{$preset};
	return $self->{preset};
}

# everything worth persisting, as a plain hash
sub state { $_[0]->{state} }

sub _now { $_[0]->{now}->() }

sub _limits { $PRESETS{ $_[0]->{preset} } }

sub _new { +{ gap => $_[0]->_limits->{start}, streak => 0, refused => 0, ok => 0, failed => 0 } }

# for recording: creates the host's entry
sub _host {
	my ($self, $host) = @_;
	return $self->{state}->{hosts}->{ lc $host } ||= $self->_new;
}

# for reading: a host we've never used gets the defaults, without being remembered
sub _peek {
	my ($self, $host) = @_;
	return $self->{state}->{hosts}->{ lc $host } || $self->_new;
}

sub hostOf {
	my ($class, $url) = @_;
	my ($host) = ($url || '') =~ m{^[a-z][a-z0-9+.-]*://(?:[^/@]*@)?([^/:?#]+)}i;
	return lc($host || '');
}

# When may a background download from $host start? (epoch seconds; <= now means now)
sub readyAt {
	my ($self, $host) = @_;
	my $h = $self->_peek($host);

	my $gapEnd = ($h->{lastEnd} || 0) + $h->{gap};
	my $cool   = $h->{coolUntil} || 0;

	return $gapEnd > $cool ? $gapEnd : $cool;
}

# Is the host asking us to wait, whatever the gap? Returns the time it ends, or 0.
sub coolingUntil {
	my ($self, $host) = @_;
	my $until = $self->_peek($host)->{coolUntil} || 0;
	return $until > $self->_now ? $until : 0;
}

# Record how a download from $host went.
#   ok => 1, bytes, secs     a clean download
#   code => HTTP status, retryAfter => seconds    a failure
sub finished {
	my ($self, $host, %r) = @_;

	my $h   = $self->_host($host);
	my $now = $self->_now;
	my $lim = $self->_limits;

	$h->{lastEnd} = $now;

	if ($r{ok}) {
		$h->{ok}++;
		$h->{streak}  = 0;
		$h->{refused} = 0;
		$h->{reason}  = undef;

		my $bps = $r{secs} && $r{secs} > 0 && $r{bytes} ? $r{bytes} / $r{secs} : undef;

		if ($bps && $h->{bps} && $bps < SLOW * $h->{bps} && $r{bytes} > 1_000_000) {
			# much slower than usual: the server may be throttling us quietly
			$h->{gap} = _min(MAX_GAP, $h->{gap} * 1.5);
			$h->{reason} = 'slower than usual';
		}
		else {
			$h->{gap} = _max($lim->{min}, $h->{gap} * 0.85);
		}

		if ($bps) {
			$h->{bps} = $h->{bps} ? 0.7 * $h->{bps} + 0.3 * $bps : $bps;
			$self->_capacity($bps);
		}
		return;
	}

	$h->{failed}++;
	my $code = $r{code} || 0;

	return if $GONE{$code};    # that file is missing; the server is fine

	if ($THROTTLE{$code}) {
		$h->{streak}++;
		my $wait = $r{retryAfter} && $r{retryAfter} > 0 ? _min(BLOCKED, $r{retryAfter}) : $BACKOFF[ _min($#BACKOFF, $h->{streak} - 1) ];
		$h->{coolUntil} = $now + $wait;
		$h->{gap}    = _min(MAX_GAP, $h->{gap} * 2);
		$h->{reason} = "HTTP $code" . ($r{retryAfter} ? ', as the server asked' : '');
	}
	elsif ($REFUSED{$code}) {
		$h->{refused}++;
		if ($h->{refused} >= 2) {
			$h->{coolUntil} = $now + BLOCKED;
			$h->{reason}    = "HTTP $code twice: probably blocked";
		}
	}
	else {
		$h->{streak}++;
		$h->{gap} = _min(MAX_GAP, $h->{gap} * 1.5);
		if ($h->{streak} >= 3) {
			$h->{coolUntil} = $now + $BACKOFF[ _min($#BACKOFF, $h->{streak} - 3) ];
			$h->{reason}    = 'repeated failures' . ($code ? " (HTTP $code)" : '');
		}
	}
}

# the connection's download capacity in bytes/s: the fastest of the recent downloads,
# decaying slowly so an old best doesn't count for ever
sub _capacity {
	my ($self, $bps) = @_;
	my $s = $self->{state};

	my $cap = $s->{capacity} || 0;
	$cap *= 0.98 if $cap;
	$s->{capacity} = $bps > $cap ? $bps : $cap;
}

sub capacity { $_[0]->{state}->{capacity} }

# for the settings page: one row per host, busiest first
sub summary {
	my $self = shift;
	my $now  = $self->_now;
	my $hosts = $self->{state}->{hosts};

	return [ map {
		my $h = $hosts->{$_};
		+{
			host      => $_,
			gap       => int($h->{gap}),
			coolUntil => ($h->{coolUntil} || 0) > $now ? $h->{coolUntil} : undef,
			readyIn   => _max(0, int($self->readyAt($_) - $now)),
			reason    => $h->{reason},
			ok        => $h->{ok},
			failed    => $h->{failed},
			bps       => $h->{bps},
		}
	} sort { ($hosts->{$b}->{ok} + $hosts->{$b}->{failed}) <=> ($hosts->{$a}->{ok} + $hosts->{$a}->{failed}) || $a cmp $b } keys %$hosts ];
}

sub _min { $_[0] < $_[1] ? $_[0] : $_[1] }
sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }

1;
