package Preload::WarningB;
use strict;
use warnings;

BEGIN {
    local $.;
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::WB //= 0;
    warn "Loaded ${ \__PACKAGE__ } again.\n" if $PRELOAD::WB++;
}

sub WB { $PRELOAD::WB }

die "PreDefined sub is missing!" unless __PACKAGE__->can('PreDefined');

1;
