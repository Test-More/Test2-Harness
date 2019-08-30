package App::Yath::Plugin::SysInfo;
use strict;
use warnings;

our $VERSION = '0.001091';

use Sys::Hostname qw/hostname/;

use parent 'App::Yath::Plugin';

sub inject_run_data {
    my $class  = shift;
    my %params = @_;

    my $meta   = $params{meta};
    my $fields = $params{fields};

    my $hostname = hostname;

    my $short = $hostname;
    $short =~ s/\..*$//g;

    push @$fields => {
        name    => 'hostname',
        details => $short,
        raw     => $hostname,
    };

    push @$fields => {
        name    => 'user',
        details => $ENV{USER},
    } if $ENV{USER};
}

1;
