package Test2::Harness::Runner::Preload;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/cluck/;

use parent 'Test2::Harness::Preload';

cluck "Test2::Harness::Runner::Preload is deprecated, use Test2::Harness::Preload instead (hint 'Runner::' has been removed)";

1;
