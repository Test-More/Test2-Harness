package Preload;
use strict;
use warnings;

use Test2::Harness::Runner::Preload;

print "$$ $0 - Loaded ${ \__PACKAGE__ }\n";

stage A => sub {
    default();

    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';
};

stage B => sub {
    preload 'Preload::A';
    preload 'Preload::WarningA';
    preload 'Preload::ExceptionA';
    preload 'Preload::ExporterA';

    preload 'Preload::B';
    preload 'Preload::WarningB';
    preload 'Preload::ExceptionB';
    preload 'Preload::ExporterB';

    preload 'Preload::IncChange';
};

1;
