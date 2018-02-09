package Test2::Harness::UI::Controller::Dashboard;
use strict;
use warnings;

use Test2::Harness::UI::Response qw/resp error/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;

sub title { 'Dashboard' }

sub handle {
    my $self = shift;

    return resp(200, ['Content-Type' => 'text/html'], "TODO");
}

1;
