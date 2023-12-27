package Preload::ExceptionA;
use strict;
use warnings;

BEGIN {
    local $.;
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::ExA //= 0;
    die "Loaded ${ \__PACKAGE__ } again.\n" if $PRELOAD::ExA++;
}

sub ExA { $PRELOAD::ExA }

1;
