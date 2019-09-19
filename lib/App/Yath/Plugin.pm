package App::Yath::Plugin;
use strict;
use warnings;

our $VERSION = '0.001100';

sub options {}

sub pre_init {}

sub post_init {}

sub post_run {}

sub find_files {}

sub munge_files {}

sub block_default_search {}

sub claim_file {}

sub inject_run_data {}

sub TO_JSON { ref($_[0]) || "$_[0]" }

1;
