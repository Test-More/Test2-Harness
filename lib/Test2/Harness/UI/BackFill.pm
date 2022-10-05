package Test2::Harness::UI::BackFill;
use strict;
use warnings;

our $VERSION = '0.000128';

use Data::Dumper;
use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::UI::Util qw/parse_duration is_invalid_subtest_name/;

use Test2::Harness::UI::Util::HashBase qw{
    <config
};

sub backfill_durations {
    my $self = shift;

    my $runs = $self->config->schema->resultset('Run')->search(
        {status   => {'-in' => [qw/complete canceled/]}},
        {order_by => 'run_ord',}
    );

    while (my $run = $runs->next) {
        if ($run->reportings->count) {
            print "Run " . $run->run_id . " is already populated with durations data.\n";
            next;
        }

        my $buffer = [];
        print "Starting run " . $run->run_id . "...\n";

        my %run_data = (
            project_id => $run->project_id,
            run_id     => $run->run_id,
            run_ord    => $run->run_ord,
            user_id    => $run->user_id,
        );

        if (my $duration = $run->duration) {
            my $fail  = $run->failed               ? 1 : 0;
            my $pass  = $run->failed               ? 0 : 1;
            my $abort = $run->status ne 'complete' ? 1 : 0;
            $fail = 0 if $abort;
            $pass = 0 if $abort;

            push @$buffer => {
                %run_data,
                reporting_id => gen_uuid(),
                duration     => parse_duration($duration),
                retry        => 0,
                pass         => $pass,
                fail         => $fail,
                abort        => $abort,
            };
        }

        my $jobs = $run->jobs;
        while (my $job = $jobs->next) {
            next unless $job->test_file_id;

            print "  Starting job " . $job->test_file->filename . " " . ($job->job_try || 0) . "...\n";
            my %job_data = (
                %run_data,
                job_try      => $job->job_try // 0,
                job_key      => $job->job_key,
                test_file_id => $job->test_file_id,
            );

            if (my $duration = $job->duration) {
                my $fail  = $job->fail  ? 1 : 0;
                my $pass  = $job->fail  ? 0 : 1;
                my $retry = $job->retry ? 1 : 0;
                my $abort = $job->ended ? 0 : 1;

                push @$buffer => {
                    %job_data,
                    reporting_id => gen_uuid(),
                    duration     => parse_duration($duration),
                    pass         => $pass,
                    fail         => $fail,
                    retry        => $retry,
                    abort        => $abort,
                };
            }

            my $events = $job->events->search({is_subtest => 1, nested => 0});
            while (my $e = $events->next()) {
                my $f = $e->facets or next;
                next if $f->{hubs}->[0]->{nested};

                my $parent = $f->{parent}       // next;
                my $assert = $f->{assert}       // next;
                my $st     = $assert->{details} // next;
                next if is_invalid_subtest_name($st);

                my $start    = $parent->{start_stamp} // next;
                my $stop     = $parent->{stop_stamp}  // next;
                my $duration = $stop - $start         // next;

                print "    Adding subtest '$st'\n";
                push @$buffer => {
                    %job_data,
                    reporting_id => gen_uuid(),
                    duration     => $duration,
                    subtest      => $st,
                    event_id     => $e->event_id,
                    abort        => 0,
                    retry        => 0,
                    $assert->{pass} ? (pass => 1, fail => 0) : (fail => 1, pass => 0),
                };
            }
        }

        unless (@$buffer) {
            print "No durations to add.\n\n";
            next;
        }

        local $ENV{DBIC_DT_SEARCH_OK} = 1;
        unless (eval { $self->config->schema->resultset('Reporting')->populate($buffer); 1 }) {
            warn "Failed to populate reporting!\n$@\n" . Dumper($buffer);
        }
    }
}

1;
