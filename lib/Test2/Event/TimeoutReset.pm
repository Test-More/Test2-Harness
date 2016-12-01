package Test2::Event::TimeoutReset;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase;

sub diagnostics { 1 }

sub summary { 'Event received, timeout reset.' }

1;
