package Plugins::PodcastCache::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::PodcastCache::Status;

my $prefs = preferences('plugin.podcastcache');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_PODCASTCACHE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PodcastCache/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(cacheRoot playWait prefetch prefetchHours quietStart quietEnd));
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{saveSettings}) {
		my $default = _keepFromForm($params->{default_mode}, $params->{default_n});

		if (defined $default) {
			$prefs->set(defaultKeep => $default);
		}
		else {
			$params->{warning} .= 'The default number of episodes to keep must be between 1 and 999.<br>';
		}

		# fields are numbered, with the feed url in a hidden field, as urls make poor names
		my %feedKeep = %{ $prefs->get('feedKeep') || {} };

		for (my $i = 0; defined(my $url = $params->{"feed_url_$i"}); $i++) {
			my $mode = $params->{"feed_mode_$i"} || 'default';

			if ($mode eq 'default') {
				delete $feedKeep{$url};
				next;
			}

			my $keep = _keepFromForm($mode, $params->{"feed_n_$i"});

			if (defined $keep) {
				$feedKeep{$url} = $keep;
			}
			else {
				$params->{warning} .= 'The number of episodes to keep must be between 1 and 999.<br>';
			}
		}

		$prefs->set(feedKeep => \%feedKeep);

		# apply the new limits
		Plugins::PodcastCache::Retention->scheduleAll(1);
	}

	my $default = $prefs->get('defaultKeep');
	my $feedKeep = $prefs->get('feedKeep') || {};

	$params->{defaultKeep}  = _keepForForm($default);
	$params->{defaultLabel} = Plugins::PodcastCache::Plugin::keepLabel($default);

	$params->{feeds} = [ map {
		my $keep = $feedKeep->{ $_->{value} };
		{
			name => $_->{name},
			url  => $_->{value},
			%{ defined $keep ? _keepForForm($keep) : { mode => 'default', n => $default =~ /^\d+$/ ? $default : 3 } },
		};
	} @{ preferences('plugin.podcast')->get('feeds') || [] } ];

	$params->{status} = Plugins::PodcastCache::Status->summary;

	return $class->SUPER::handler($client, $params);
}

# form (mode, number) -> pref value: a number, 'all' or 'current'; undef if invalid
sub _keepFromForm {
	my ($mode, $n) = @_;

	return $mode if $mode && ($mode eq 'all' || $mode eq 'current');

	$n = '' unless defined $n;
	$n =~ s/^\s+|\s+$//g;

	return $n =~ /^[1-9]\d{0,2}$/ ? $n : undef;
}

sub _keepForForm {
	my $keep = shift;

	return { mode => $keep, n => 3 } if $keep eq 'all' || $keep eq 'current';
	return { mode => 'newest', n => $keep };
}

1;
