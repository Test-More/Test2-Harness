package App::Yath::Renderer;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Util::Table qw/table/;
use Getopt::Yath::Term qw/USE_COLOR/;

use Carp qw/croak/;
use List::Util qw/max/;

use Test2::Harness::Util::HashBase qw{
    <color
    <hide_runner_output
    <progress
    <quiet
    <show_times
    <term_width
    <truncate_runner_output
    <verbose
    <wrap
    <interactive
    <is_persistent
    <show_job_end
    <show_job_info
    <show_job_launch
    <show_run_info
    <show_run_fields
    <settings
};

sub init {
    my $self = shift;

    croak "'settings' is required" unless $self->{+SETTINGS};
}

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub start  { }
sub step   { }
sub signal { }

sub weight { 0 }

sub finish {
    my $self = shift;
    my ($auditor) = @_;

    my $final_data = $auditor->final_data;
    my $summary    = $auditor->summary;

    $self->render_final_data($final_data);
    $self->render_summary($summary);
}

sub render_summary {
    my $self = shift;
    my ($summary) = @_;

    my $pass         = $summary->{pass};
    my $time_data    = $summary->{time_data};
    my $cpu_usage    = $summary->{cpu_usage};
    my $failures     = $summary->{failures};
    my $tests_seen   = $summary->{tests_seen};
    my $asserts_seen = $summary->{asserts_seen};

    return if $self->quiet > 1;

    my @summary = (
        $failures ? ("     Fail Count: $failures") : (),
        "     File Count: $tests_seen",
        "Assertion Count: $asserts_seen",
        $time_data
        ? (
            sprintf("      Wall Time: %.2f seconds",                                                       $time_data->{wall}),
            sprintf("       CPU Time: %.2f seconds (usr: %.2fs | sys: %.2fs | cusr: %.2fs | csys: %.2fs)", @{$time_data}{qw/cpu user system cuser csystem/}),
            sprintf("      CPU Usage: %i%%",                                                               $cpu_usage),
            )
        : (),
    );

    my $res = "    -->  Result: " . ($pass ? 'PASSED' : 'FAILED') . "  <--";
    if ($self->color && USE_COLOR) {
        require Term::ANSIColor;
        my $color = $pass ? Term::ANSIColor::color('bold bright_green') : Term::ANSIColor::color('bold bright_red');
        my $reset = Term::ANSIColor::color('reset');
        $res = "$color$res$reset";
    }
    push @summary => $res;

    my $msg    = "Yath Result Summary";
    my $length = max map { length($_) } @summary;
    my $prefix = ($length - length($msg)) / 2;

    print "\n";
    print " " x $prefix;
    print "$msg\n";
    print "-" x $length;
    print "\n";
    print join "\n" => @summary;
    print "\n";
}

sub render_final_data {
    my $self = shift;
    my ($final_data) = @_;

    return if $self->quiet > 1;

    if (my $rows = $final_data->{retried}) {
        print "\nThe following jobs failed at least once:\n";
        print join "\n" => table(
            header => ['Job ID', 'Times Run', 'Test File', "Succeeded Eventually?"],
            rows   => [sort { $a->[2] cmp $b->[2] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        print join "\n" => table(
            collapse => 1,
            header   => ['Job ID', 'Test File', 'Subtests'],
            rows     => [map { my $r = [@{$_}]; $r->[2] = join("\n", @{$r->[2]}) if $r->[2]; $r } sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File', "Reason"],
            rows   => [sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => [sort { $a->[1] cmp $b->[1] } @$rows],
        );
        print "\n";
    }
}

1;
