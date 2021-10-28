package Preload::ExporterB;
use strict;
use warnings;

BEGIN {
    print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";
    $PRELOAD::EB //= 0;
    $PRELOAD::EB++;
}

our @EXPORT_OK = ('EB');

sub import { 1 }

sub EB { $PRELOAD::EB }

1;

