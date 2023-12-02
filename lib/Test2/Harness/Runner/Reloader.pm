package Test2::Harness::Runner::Reloader;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::Deprecated(
    replaced => ['Test2::Harness::Reloader', 'Test2::Harness::Reloader::Stat', 'Test2::Harness::Reloader::Inotify2'],
);

1;
