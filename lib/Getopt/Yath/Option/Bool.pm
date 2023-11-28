package Getopt::Yath::Option::Bool;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Getopt::Yath::Option';
use Test2::Harness::Util::HashBase;

sub allows_shortval   { 0 }
sub allows_default    { 1 }
sub allows_arg        { 0 }
sub requires_arg      { 0 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }

sub no_arg_value { 1 }    # --bool

# undef is not populated, otherwise qw have 1 or 0
sub is_populated { defined(${$_[1]}) ? 1 : 0 }

sub add_value   { ${$_[1]} = $_[2] }
sub clear_field { ${$_[1]} = 0 }       # --no-bool

# Default to 0 unless otherwise specified
sub get_default_value {
    my $self = shift;
    return undef if $self->{+MAYBE};
    return $self->SUPER::get_default_value(@_) ? 1 : 0;
}

sub can_set_env   { 1 }

sub get_env_value {
    my $opt = shift;
    my ($var, $ref) = @_;

    my $b = $$ref ? 1 : 0;
    return $b unless $var =~ m/^!/;
    return $b ? 0 : 1;
}

1;
