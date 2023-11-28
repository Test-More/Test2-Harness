package Getopt::Yath::Option::AutoMap;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Getopt::Yath::Option::Map';
use Test2::Harness::Util::HashBase;

sub allows_arg        { 1 }
sub requires_arg      { 0 }
sub allows_default    { 1 }
sub allows_autofill   { 1 }
sub requires_autofill { 1 }

sub default_long_examples  { ['', '=key=val'] }
sub default_short_examples { ['', 'key=val', '=key=val'] }

1;
