package Test2::Harness::Parser;
use strict;
use warnings;

use Test2::Util::HashBase;
use Scalar::Util qw/blessed/;

sub parse {
    my $self = shift;
    my $class = blessed($self);
    die "class '$class' needs to override sub parse()";
}

1;
