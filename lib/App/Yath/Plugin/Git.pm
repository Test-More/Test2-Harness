package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '0.001100';

use IPC::Cmd qw/can_run/;
use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class  = shift;
    my %params = @_;

    my $meta   = $params{meta};
    my $fields = $params{fields};

    my $long_sha  = $ENV{GIT_LONG_SHA};
    my $short_sha = $ENV{GIT_SHORT_SHA};
    my $status    = $ENV{GIT_STATUS};
    my $branch    = $ENV{GIT_BRANCH};

    if (my $cmd = can_run('git')) {
        chomp($long_sha  ||= `$cmd rev-parse HEAD`);
        chomp($short_sha ||= `$cmd rev-parse --short HEAD`);
        chomp($status    ||= `$cmd status -s`);
        chomp($branch    ||= `$cmd rev-parse --abbrev-ref HEAD`);
    }

    return unless $long_sha;

    $meta->{git}->{sha}    = $long_sha;
    $meta->{git}->{status} = $status if $status;

    if ($branch) {
        $meta->{git}->{branch} = $branch;

        my $short = length($branch) > 20 ? substr($branch, 0, 20) : $branch;

        push @$fields => {name => 'git', details => $short, raw => $branch, data => $meta->{git}};
    }
    else {
        $short_sha ||= substr($long_sha, 0, 16);
        push @$fields => {name => 'git', details => $short_sha, raw => $long_sha, data => $meta->{git}};
    }

    return;
}

1;
