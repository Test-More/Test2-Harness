package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '0.001087';

use IPC::Cmd qw/can_run/;
use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class = shift;
    my %params = @_;

    my $meta = $params{meta};
    my $fields = $params{fields};

    my $cmd = can_run('git') or return;

    chomp(my $long_sha  = `$cmd rev-parse HEAD`);
    chomp(my $short_sha = `$cmd rev-parse --short HEAD`);
    chomp(my $status    = `$cmd status -s`);

    $meta->{git}->{sha}       = $long_sha;
    $meta->{git}->{sha_short} = $short_sha;
    $meta->{git}->{status}    = $status;

    push @$fields => { name => 'git_sha', details => $short_sha, data => $meta->{git} };

    return;
}

1;
