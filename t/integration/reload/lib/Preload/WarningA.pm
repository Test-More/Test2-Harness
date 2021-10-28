package Preload::WarningA;
use strict;
use warnings;

BEGIN {
    local $.;
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::WA //= 0;
    warn "Loaded ${ \__PACKAGE__ } again.\n" if $PRELOAD::WA++;
}

sub WA { $PRELOAD::WA }

die "PreDefined sub is missing!" unless __PACKAGE__->can('PreDefined');

1;
