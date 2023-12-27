package App::Yath::Command::fake;
use strict;
use warnings;

use parent 'App::Yath::Command';

use App::Yath::Options;

option_group {prefix => 'fake'}, sub {
    option($_, short => $_) for qw/x y z/;

    post sub { print "\n\nAAAA\n\n";  $main::POST_HOOK++ };
};

1;
