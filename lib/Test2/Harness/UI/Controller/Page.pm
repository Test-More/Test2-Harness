package Test2::Harness::UI::Controller::Page;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'Test2::Harness::UI::Controller';
use Test2::Harness::UI::Util::HashBase;
use Test2::Harness::UI::ControllerRole::UseSession;
use Test2::Harness::UI::ControllerRole::HTML;

sub title { 'TODO' }

sub process_request {
    my $self = shift;

    return ("TODO", ['Content-Type' => 'text/html']);
}

1;
