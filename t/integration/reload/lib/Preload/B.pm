package Preload::B;
use strict;
use warnings;

BEGIN {
    print STDERR "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::B //= 0;
    $PRELOAD::B++;
}

sub B { $PRELOAD::B }

die "PreDefined sub is missing!" unless Preload::X->can('PreDefined');

1;
