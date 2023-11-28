package Getopt::Yath::Option::Scalar;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Getopt::Yath::Option';
use Test2::Harness::Util::HashBase;

sub allows_default    { 1 }
sub allows_arg        { 1 }
sub requires_arg      { 1 }
sub allows_autofill   { 0 }
sub requires_autofill { 0 }

sub is_populated { defined(${$_[1]}) ? 1 : 0 }

sub add_value { ${$_[1]} = $_[2] }

sub can_set_env   { 1 }

sub get_env_value {
    my $opt = shift;
    my ($var, $ref) = @_;

    return $$ref unless $var =~ m/^!/;
    return $ref ? 0 : 1;
}


1;
