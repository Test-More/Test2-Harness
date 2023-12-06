package Test2::Harness::Collector::Auditor;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase;

sub init {}

sub audit { croak "'$_[0]' does not implement audit()" }
sub pass { croak "'$_[0]' does not implement pass()" }
sub fail { croak "'$_[0]' does not implement fail()" }
sub has_exit { croak "'$_[0]' does not implement has_exit()" }
sub has_plan { croak "'$_[0]' does not implement has_plan()" }

1;
