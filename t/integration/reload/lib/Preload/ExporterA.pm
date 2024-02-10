package Preload::ExporterA;
use strict;
use warnings;

BEGIN {
    print STDERR "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::EA //= 0;
    $PRELOAD::EA++;
}

use parent 'Exporter';
our @EXPORT_OK = 'EA';

sub EA { $PRELOAD::EA }

1;
