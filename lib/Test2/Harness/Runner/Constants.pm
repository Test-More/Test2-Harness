package Test2::Harness::Runner::Constants;
use strict;
use warnings;

our $VERSION = '0.001100';

use Importer Importer => 'import';

our @EXPORT = qw/CATEGORIES DURATIONS/;

use constant CATEGORIES => {general => 1, isolation => 1, immiscible => 1};
use constant DURATIONS  => {long    => 1, medium    => 1, short      => 1};

1;
