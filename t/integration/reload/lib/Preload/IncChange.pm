package Preload::IncChange;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
}

die "PreDefined sub is missing!" unless __PACKAGE__->can('PreDefined');

1;
