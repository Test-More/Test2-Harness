package Test2::Harness::Renderer::Formatter;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Util::Deprecated(
    delegate => 'App::Yath::Renderer::Formatter',
    append   => "!!! Some API changes may result in your renderer being BROKEN !!!",
);

1;
