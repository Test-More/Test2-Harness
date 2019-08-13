package App::Yath::Plugin::Git;
use strict;
use warnings;

our $VERSION = '0.001082';

use IPC::Cmd qw/can_run/;
use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class = shift;
    my ($meta) = @_;

    my $cmd = can_run('git') or return;

    chomp(my $long_sha  = `$cmd rev-parse HEAD`);
    chomp(my $short_sha = `$cmd rev-parse --short HEAD`);
    chomp(my $status    = `$cmd status -s`);

    $meta->{git}->{sha}       = $long_sha;
    $meta->{git}->{sha_short} = $short_sha;
    $meta->{git}->{status}    = $status;

    return;
}

1;
