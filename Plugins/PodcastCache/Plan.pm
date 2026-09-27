package Plugins::PodcastCache::Plan;

# Which of a feed's episodes to download, in what order. No LMS modules, so it can be
# tested on its own.
#
#   plan(\@episodes, keep => N|'all'|'current', backfill => 0|1, first => N, allCount => N)
#     -> ( [ priority, episode, order ], ... )
#
# NEWEST:   the newest N (keep = N), or the newest allCount (keep = 'all')
# FIRST:    with the back catalogue on, the first `first` episodes, oldest first
# BACKFILL: with the back catalogue on, everything else, newest first
# Each episode appears once, at its highest priority. `order` sorts within a priority.

use strict;

use Exporter qw(import);

use constant {
	PLAY     => 0,
	NEWEST   => 1,
	FIRST    => 2,
	BACKFILL => 3,
};

our @EXPORT_OK = qw(PLAY NEWEST FIRST BACKFILL plan);

sub plan {
	my ($episodes, %opt) = @_;

	my $keep  = defined $opt{keep} ? $opt{keep} : 'current';
	my $count = $keep =~ /^\d+$/ ? $keep : $keep eq 'all' ? ($opt{allCount} || 3) : 0;
	return () unless $count;

	my @desc = sort { ($b->{pubdate} || 0) <=> ($a->{pubdate} || 0) } @{ $episodes || [] };

	# never slice past the end: grep aliases its list, and aliasing a slice element beyond
	# the end of an array extends the array with an undefined element
	my @wanted = map { [ NEWEST, $_ ] } _firstN(\@desc, $count);

	if ($keep eq 'all' && $opt{backfill}) {
		my @asc = reverse @desc;
		push @wanted, map { [ FIRST, $_ ] } _firstN(\@asc, $opt{first} || 0);
		push @wanted, map { [ BACKFILL, $_ ] } @desc;
	}

	my %seen;
	return map {
		my ($priority, $ep) = @$_;
		[ $priority, $ep, $priority == FIRST ? ($ep->{pubdate} || 0) : -($ep->{pubdate} || 0) ]
	} grep { !$seen{ $_->[1]->{url} }++ } @wanted;
}

sub _firstN {
	my ($list, $n) = @_;
	$n = @$list if $n > @$list;
	return $n > 0 ? @$list[0 .. $n - 1] : ();
}

1;
