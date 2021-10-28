package Preload::ExporterA;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::EA //= 0;
    $PRELOAD::EA++;
}

use parent 'Exporter';
our @EXPORT_OK = 'EA';

sub EA { $PRELOAD::EA }

die "PreDefined sub is missing!" unless __PACKAGE__->can('PreDefined');

1;
