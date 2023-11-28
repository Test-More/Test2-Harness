package Getopt::Yath::Option::AutoList;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'Getopt::Yath::Option::List';
use Test2::Harness::Util::HashBase;

sub allows_arg        { 1 }
sub requires_arg      { 0 }
sub allows_autofill   { 1 }
sub requires_autofill { 1 }

1;
