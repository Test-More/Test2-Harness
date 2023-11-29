package Test2::Harness::Runner::Preload::Stage;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/cluck/;

use parent 'Test2::Harness::Preload::Stage';

cluck "Test2::Harness::Runner::Preload::Stage is deprecated, use Test2::Harness::Preload::Stage instead (hint 'Runner::' has been removed)";

1;
