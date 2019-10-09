package App::Yath::Command::fake;
use strict;
use warnings;

use parent 'App::Yath::Command';

use App::Yath::Options;

option_group {prefix => 'fake'}, sub {
    option($_, short => $_) for qw/x y z/;

    option post_hook => (
        post_process => sub { print "\n\nAAAA\n\n";  $main::POST_HOOK++ },
    );

    option pre_hook => (
        post_process => sub { print "\n\nBBBB\n\n"; $main::PRE_HOOK++ },
    );
};

1;
