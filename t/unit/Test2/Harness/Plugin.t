use Test2::V0;

__END__

package Test2::Harness::Plugin;
use strict;
use warnings;

our $VERSION = '0.001100';

sub find_files {}

sub munge_files {}

sub block_default_search {}

sub claim_file {}

sub inject_run_data {}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;
