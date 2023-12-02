package Test2::Harness::Renderer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::Deprecated(
    delegate => 'App::Yath::Renderer',
    append   => "!!! Some API changes may result in your renderer being BROKEN !!!",
);

1;
