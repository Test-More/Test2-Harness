package App::Yath::Plugin::SysInfo;
use strict;
use warnings;

our $VERSION = '0.001100';

use Sys::Hostname qw/hostname/;
use Test2::Util qw/CAN_THREAD CAN_REALLY_FORK CAN_FORK CAN_SIGSYS/;
use Config qw/%Config/;

use parent 'App::Yath::Plugin';
use Test2::Harness::Util::HashBase qw/-host_short_pattern/;

sub inject_run_data {
    my $self  = shift;
    my %params = @_;

    my $meta   = $params{meta};
    my $fields = $params{fields};

    my %data = (
        env => {
            user  => $ENV{USER},
            shell => $ENV{SHELL},
            term  => $ENV{TERM},
        },

        ipc => {
            can_fork        => CAN_FORK(),
            can_really_fork => CAN_REALLY_FORK(),
            can_thread      => CAN_THREAD(),
            can_sigsys      => CAN_SIGSYS(),
        },
    );

    my ($short, $raw) = ('sys', 'system info');

    if (my $hostname = hostname()) {
        $short = undef;
        $data{hostname} = $hostname;
        $raw = $hostname;

        if (my $pattern = $self->{+HOST_SHORT_PATTERN}) {
            if ($hostname =~ /($pattern)/) {
                $short = $1;
            }
        }

        unless ($short) {
            $short = $hostname;
            $short =~ s/\.[^\.]*$// while length($short) > 18 && $short =~ m/\./;
        }
    }

    my @fields = qw/uselongdouble use64bitall version use64bitint usemultiplicity osname useperlio useithreads archname/;
    @{$data{config}}{@fields} = @Config{@fields};

    push @$fields => {
        name    => 'sys',
        details => $short,
        raw     => $raw,
        data    => \%data,
    };
}

sub TO_JSON { ref($_[0]) }

1;
