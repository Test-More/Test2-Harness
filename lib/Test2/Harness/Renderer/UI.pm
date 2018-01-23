package Test2::Harness::Renderer::UI;
use strict;
use warnings;

use Carp qw/croak/;

use POSIX;

BEGIN { require Test2::Harness::Renderer; our @ISA = ('Test2::Harness::Renderer') }
use Test2::Harness::Util::HashBase;

sub init {
    my $self = shift;
}

sub render_event {
    my $self = shift;
    my ($event) = @_;
}

1;
