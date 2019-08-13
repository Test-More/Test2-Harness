package Test2::Plugin::DBIProfile;
use strict;
use warnings;

our $VERSION = '0.001081';

use DBI::Profile;
use Test2::API qw/test2_add_callback_exit/;

my $ADDED_HOOK = 0;

sub import {
    $ENV{DBI_PROFILE} //= "!MethodClass";
    $DBI::Profile::ON_DESTROY_DUMP = undef;
    $DBI::Profile::ON_FLUSH_DUMP   = undef;
    test2_add_callback_exit(\&send_profile_event) unless $ADDED_HOOK++;
}

sub send_profile_event {
    my ($ctx, $real, $new) = @_;

    my $p = $DBI::shared_profile or return;

    my $data = $p->{Data};
    my ($summary) = $p->format;

    $ctx->send_ev2('DBIProfile' => $data, info => [{tag => 'NOTE', details => $summary}]);
}

1;
