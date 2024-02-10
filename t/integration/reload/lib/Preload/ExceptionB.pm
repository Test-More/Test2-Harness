package Preload::ExceptionB;
use strict;
use warnings;

BEGIN {
    local $.;
    print STDERR "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::ExB //= 0;
    die "Loaded ${ \__PACKAGE__ } again.\n" if $PRELOAD::ExB++;
}

sub ExB { $PRELOAD::ExB }

1;

