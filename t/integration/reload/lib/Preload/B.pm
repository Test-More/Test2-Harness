package Preload::B;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::B //= 0;
    $PRELOAD::B++;
}

sub B { $PRELOAD::B }

die "PreDefined sub is missing!" unless __PACKAGE__->can('PreDefined');

1;
