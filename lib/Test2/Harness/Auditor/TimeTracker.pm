package Test2::Harness::Auditor::TimeTracker;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::Deprecated(
    delegate => 'Test2::Harness::Log::TimeTracker',
);

1;
