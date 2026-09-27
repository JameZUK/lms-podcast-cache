#!/usr/bin/perl
# Tests for Plugins::PodcastCache::Plan (which episodes to download, in what order).
# Runs without LMS:  prove -I. tests/plan.t

use strict;
use warnings;

use Test::More;

use Plugins::PodcastCache::Plan qw(NEWEST FIRST BACKFILL plan);

# ten episodes, ep1 oldest .. ep10 newest, given out of order
my @eps = map { { url => "ep$_", pubdate => 1_000_000 + $_ * 86400 } } (3, 10, 1, 7, 5, 2, 9, 4, 6, 8);

sub urls { [ map { $_->[1]->{url} } @_ ] }
sub prios { [ map { $_->[0] } @_ ] }

subtest 'keep newest N' => sub {
	my @p = plan(\@eps, keep => 3);
	is_deeply urls(@p), [qw(ep10 ep9 ep8)], 'the newest three, newest first';
	is_deeply prios(@p), [NEWEST, NEWEST, NEWEST], 'all NEWEST';
};

subtest 'keep all, no back catalogue: newest allCount' => sub {
	is_deeply urls(plan(\@eps, keep => 'all')), [qw(ep10 ep9 ep8)], 'default 3';
	is_deeply urls(plan(\@eps, keep => 'all', allCount => 2)), [qw(ep10 ep9)], 'allCount honoured';
	is_deeply urls(plan(\@eps, keep => 'all', first => 2)), [qw(ep10 ep9 ep8)], 'first ignored without back catalogue';
};

subtest 'keep all with the back catalogue: newest, then start of series, then the rest' => sub {
	my @p = plan(\@eps, keep => 'all', backfill => 1, first => 2);
	is_deeply urls(@p), [qw(ep10 ep9 ep8 ep1 ep2 ep7 ep6 ep5 ep4 ep3)], 'every episode once, in this order';
	is_deeply prios(@p), [NEWEST, NEWEST, NEWEST, FIRST, FIRST, (BACKFILL) x 5], 'priorities';

	# the queue sorts by (priority, order): check that gives the same order
	my @sorted = sort { $a->[0] <=> $b->[0] || $a->[2] <=> $b->[2] } reverse @p;
	is_deeply urls(@sorted), urls(@p), 'order keys sort the queue the same way';
};

subtest 'first 0, or more than there are' => sub {
	is_deeply urls(plan(\@eps, keep => 'all', backfill => 1, first => 0)),
		[qw(ep10 ep9 ep8 ep7 ep6 ep5 ep4 ep3 ep2 ep1)], 'no start of series: newest first throughout';
	my @p = plan([ @eps[0 .. 1] ], keep => 'all', backfill => 1, first => 5);
	is scalar(@p), 2, 'two episodes, each once';
};

subtest 'back catalogue only with keep all' => sub {
	is_deeply urls(plan(\@eps, keep => 3, backfill => 1, first => 2)), [qw(ep10 ep9 ep8)], 'keep N: no back catalogue (retention would delete it)';
	my @none = plan(\@eps, keep => 'current', backfill => 1);
	is scalar(@none), 0, "keep 'only the episode playing': nothing";
};

subtest 'missing pubdates and empty feeds' => sub {
	my @none = plan([], keep => 3);
	is scalar(@none), 0, 'empty feed';
	my @p = plan([ { url => 'a' }, { url => 'b', pubdate => 5 } ], keep => 1);
	is_deeply urls(@p), ['b'], 'undated sorts as oldest';
};

done_testing;
