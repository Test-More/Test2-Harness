package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '0.001093';

use IPC::Cmd qw/can_run/;
use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class = shift;
    my %params = @_;

    my $meta = $params{meta};
    my $fields = $params{fields};

    my $cmd = can_run('git') or return;

    chomp(my $long_sha  = $ENV{GIT_LONG_SHA}  || `$cmd rev-parse HEAD`);
    chomp(my $short_sha = $ENV{GIT_SHORT_SHA} || `$cmd rev-parse --short HEAD`);
    chomp(my $status    = $ENV{GIT_STATUS}    || `$cmd status -s`);
    chomp(my $branch    = $ENV{GIT_BRANCH}    || `git branch --show-current`);

    return unless $long_sha;

    $short_sha ||= substr($long_sha, 0, 10);

    $meta->{git}->{sha}       = $long_sha;
    $meta->{git}->{sha_short} = $short_sha;
    $meta->{git}->{status}    = $status if $status;
    $meta->{git}->{branch}    = $branch if $branch;

    push @$fields => { name => 'git_sha', details => $short_sha, raw => $long_sha, data => $meta->{git} };

    return;
}

1;
