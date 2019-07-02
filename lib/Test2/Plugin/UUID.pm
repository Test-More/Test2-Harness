package Test2::Plugin::UUID;
use strict;
use warnings;

our $VERSION = '0.001079';

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::API qw/test2_add_uuid_via/;

sub import {
    test2_add_uuid_via(\&gen_uuid);
    require Test2::Hub;
    Test2::Hub->new; # Make sure the UUID generator is found
    return;
}

1;
