package Preload::A;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::A //= 0;
    $PRELOAD::A++;
}

sub A { $PRELOAD::A }

1;
