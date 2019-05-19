package Test2::Plugin::MemUsage;
use strict;
use warnings;

our $VERSION = '0.001076';

use Test2::Harness::Util qw/maybe_read_file/;

use Test2::API qw/test2_add_callback_exit/;

my $ADDED_HOOK = 0;

sub import {
    test2_add_callback_exit(\&send_mem_event) unless $ADDED_HOOK++
}

sub send_mem_event {
    my ($ctx, $real, $new) = @_;

    my $file = "/proc/$$/status";
    return unless -f $file;

    my $stats = maybe_read_file($file) or return;

    my %mem;
    $mem{peak} = [$1, $2] if $stats =~ m/VmPeak:\s+(\d+) (\S+)/;
    $mem{size} = [$1, $2] if $stats =~ m/VmSize:\s+(\d+) (\S+)/;
    $mem{rss}  = [$1, $2] if $stats =~ m/VmRSS:\s+(\d+) (\S+)/;
    $mem{details} = "rss:  $mem{rss}->[0]$mem{rss}->[1]\nsize: $mem{size}->[0]$mem{size}->[1]\npeak: $mem{peak}->[0]$mem{peak}->[1]";

    $ctx->send_ev2(
        about  => {details => $mem{details}},
        memory => \%mem,
    );
}

1;
