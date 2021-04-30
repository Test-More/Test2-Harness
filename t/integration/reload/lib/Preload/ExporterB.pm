package Preload::ExporterB;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::EB //= 0;
    $PRELOAD::EB++;
}

use parent 'Exporter';
our @EXPORT_OK = 'EB';

sub EB { $PRELOAD::EB }

1;

