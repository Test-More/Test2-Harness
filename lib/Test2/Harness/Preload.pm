package Test2::Harness::Preload;
use strict;
use warnings;

sub preload {
    my $class = shift;
    my ($do_not_load) = @_;
    die "$class does not override preload()";
}

1;
