package App::Yath::Command::upload;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::Deprecated(
    replaced => ['App::Yath::Command::client::publish', 'App::Yath::Command::db::publish'],
    core => 1,
);

1;

