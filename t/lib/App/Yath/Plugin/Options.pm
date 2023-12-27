package App::Yath::Plugin::Options;
use strict;
use warnings;

use App::Yath::Options;

option foobar => (
    prefix => 'testplugin',
    type => 'b',
);

1;
