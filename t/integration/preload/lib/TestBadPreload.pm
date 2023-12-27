package TestBadPreload;
use strict;
use warnings;

use Test2::Harness::Runner::Preload;

stage BAD => sub {
  default;
  preload "Test2::Harness::Preload::Does::Not::Exist";
};

1;
