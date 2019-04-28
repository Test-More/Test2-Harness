package Test2::Harness::UI::Controller;
use strict;
use warnings;

our $VERSION = '0.000001';

use Carp qw/croak/;

use Test2::Harness::UI::Response qw/error/;

use Test2::Harness::UI::Util::HashBase qw/-request -config/;

sub uses_session { 1 }

sub init {
    my $self = shift;

    croak "'request' is a required attribute" unless $self->{+REQUEST};
    croak "'config' is a required attribute"  unless $self->{+CONFIG};
}

sub title  { 'Test2-Harness-UI' }
sub handle { error(501) }

sub schema { $_[0]->{+CONFIG}->schema }

1;
