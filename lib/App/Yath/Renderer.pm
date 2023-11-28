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
};

sub init {}

sub render_event { croak "$_[0] forgot to override 'render_event()'" }

sub start  { }
sub step   { }
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
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{failed}) {
        print "\nThe following jobs failed:\n";
        print join "\n" => table(
            collapse => 1,
            header   => ['Job ID', 'Test File', 'Subtests'],
            rows     => [map { my $r = [@{$_}]; $r->[2] = join("\n", @{$r->[2]}) if $r->[2]; $r } @$rows],
        );
        print "\n";
    }

    if (my $rows = $final_data->{halted}) {
        print "\nThe following jobs requested all testing be halted:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File', "Reason"],
            rows   => $rows,
        );
        print "\n";
    }

    if (my $rows = $final_data->{unseen}) {
        print "\nThe following jobs never ran:\n";
        print join "\n" => table(
            header => ['Job ID', 'Test File'],
            rows   => $rows,
        );
        print "\n";
    }
}

1;

__END__

sub run {
    my $self   = shift;
    my %params = @_;

    my $aggregators = $params{aggregators};

    delete $aggregators->{runner} if $self->hide_runner_output;

    my $harness = $self->state;

    $self->start;

    my (%handles, %done);
    my $sig;

    $SIG{INT}  = sub { $sig = 'INT' };
    $SIG{TERM} = sub { $sig = 'TERM' };

    my $seen_warn = 0;
    while (1) {
        my $not_done = 0;
        my $events   = 0;

        warn "Fix this to also read from job outputs in verbose mode" unless $seen_warn;
        warn "Fix this to also read from job outputs for failed jobs in verbose+quiet mode" unless $seen_warn;
        $seen_warn ||= 1;

        for my $name (keys %$aggregators) {
            last if $sig;
            my $id = $aggregators->{$name};
            next if $done{$id};

            $not_done++;

            unless ($handles{$id}) {
                my $agg  = $harness->shared_get(aggregator => $id) or next;
                my $file = $agg->output_file or next;
                next unless -f $file;

                if ($name eq 'runner' && $self->truncate_runner_output) {
                    $handles{$id} = Test2::Harness::Util::File::JSONL->new(name => $file, tail => 0);
                }
                else {
                    $handles{$id} = Test2::Harness::Util::File::JSONL->new(name => $file);
                }
            }

            my $reader = $handles{$id} or next;
            my @events = $reader->poll(max => 100);
            for my $event (@events) {
                last if $sig;
                $events++;

                unless ($event) {
                    $done{$id} = 1;
                    next;
                }

                $self->render_event($event);
            }
        }

        next if $events;
        last unless $not_done;

        last if $sig;

        $self->step();
        sleep 0.2;
    }

    $self->finish();

    return 0;
}

1;
