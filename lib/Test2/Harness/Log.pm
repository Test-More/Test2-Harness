package Test2::Harness::Log;
use strict;
use warnings;

our $VERSION = '1.000155';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Log - Documentation about the L<Test2::Harness> log file.

=head1 DESCRIPTION

L<Test2::Harness> aka L<App::Yath> produces a rich/complete log when asked to
do so. This module documents the log format.

=head1 COMPRESSION

Test2::Harness can output log files uncompressed, compressed in gzip, or
compressed in bzip2.

=head1 FORMAT

The log file is in jsonl format. Each line of the log can be indepentantly
parsed as json. Each line represents a single event Test2::Harness processed
during a run. These events will be in the original order Test2::Harness
processed them in (may not be chronological to when they were generated as
generation, collection, processing, and rendering are handled in different
processes. A complete log will be terminated by the string C<null>, which is
also valid json. If a log is missing this terminator it is considered an
incomplete log.

=head2 EVENTS

B<Please note:> Older versions of Test2::Harness produced less complete events,
this covers all current fields, if you are attempting to handle very old logs
some of these fields may be missing.

Each event will have the following fields:

    {
       "event_id" : "CD01CD30-D535-11EA-9B6A-D90F9664FE12",
       "job_id"   : 0,
       "job_try"  : null,
       "run_id"   : "CCF98E54-D535-11EA-915A-D70F9664FE12",
       "stamp"    : 1596423763.76517,

       "facet_data" : {
          "harness" : {
             "event_id" : "CD01CD30-D535-11EA-9B6A-D90F9664FE12",
             "job_id" : 0,
             "job_try" : null,
             "run_id" : "CCF98E54-D535-11EA-915A-D70F9664FE12"
          },

          ...
       }
    }

=over 4

=item event_id : "UUID_OR_STRING"

Typically this will be a UUID, but when UUIDs cannot be generated it may have a
different unique identifier. This will always be a string. This may never be
NULL, if it is NULL then that is a bug and should be reported.

=item job_id : "0_OR_UUID_OR_STRING"

ID C<0> is special in that it represents the test harness itself, and not an
actual test being run. Normally the job_id will be a UUID, but may be another
unique string if UUID generation is disabled or not available.

=item job_try : INTEGER_OR_NULL

For C<< job_id => 0 >> this will be C<NULL> for any other job this will be an
intgeger of 0 or greater. This is 0 for the first time a test job is run, if a
job is re-run due to failure (or any other reason) this will be incremented to
tell you what run it is. When a job is re-run it keeps the same job ID, you can
use this to distinguish events from each run of the job.

=item run_id : "UUID_OR_STRING"

This is the run_id of the entire yath test run. This should be the same for
every event in any given log.

=item stamp : UNIX_TIME_STAMP

Timestamp of the event. This is NORMALLY set when an event is generated,
however if an event does not have its own time stamp yath will give it a
timestamp upon collection. Events without timestamps happen if the test outputs
TAP instead of L<Test2::Event> objects, or if a tool misbehaves in some way.

=item facet_data : HASH

This contains all the the data of the event, such as if an assertion was made,
what file name and line number generated it, etc.

In addition to the original facets of the event, Test2::Harness may inject the
following facets (or generate completely new events to convey these facets).

=over 4

=item harness_final

This will contain the final summary data from the end of the test run.

    {
        # Was the test run a success, or were there failures?
        pass => $BOOL,

        # What tests failed?
        failed => [
            [
                $job_id,    # Job id of the job that failed
                $file,      # Test filename
            ],
            ...
        ],

        # What tests had to be retried, and did they eventually pass?
        retried => [
            [
                $job_id,            # Job id of the job that was retied
                $tries,             # Number of tries attempted
                $file,              # Test filename
                $eventually_passed, # 'YES' if it eventually passed, 'NO' if no try ever passed.
            ],
            ...
        ],

        # What tests setn a halt event (such as bail-out, or skip the rest)
        halted => [
            [
                $job_id,    # Job id of the test
                $file,      # Test filename
                $halt,      # Halt code
            ],
            ...
        ],

        # What tests were never run (maybe because of a bail-out, or an internal error)
        unseen => [
            [
                $job_id,    # Job id of the test
                $file,      # Test filename
            ],
            ...
        ],
    }

=item harness_watcher

Internal use only, subject to change, do not rely on it.

=item harness_job

A hash representation of an L<Test2::Harness::Runner::Job> object.

B<Note:> This is done via a transformation, several methods have their values
stored in this hash when the original object does not directly store them.

=item harness_job_end

    {
        file     => $provided_path_to_test_file,
        rel_file => $relative_path_to_test_file,
        abs_file => $absolute_path_to_test_file,

        fail  => $BOOL,
        retry => $INTEGER,         # Number of retries left
        stamp => $UNIX_TIMESTAMP,  # Timestamp of when the test completed

        # May not be present
        skip  => $STRING,          # Reason test was skipped (if it was skipped)
        times => $TIMING_DATA,     # See below
    }

The C<times> field is populated by calling C<data_dump()> on an
L<Test2::Harness::Auditor::TimeTracker> Object.

=item harness_job_exit

This represents when the test job exited.

    {
        exit  => $WSTAT,
        retry => $INTEGER
        stamp => $UNIX_TIMESTAMP
    }

=item harness_job_fields

Extra data attached to the harness job, usually from an
L<Test2::Harness::Plugin> via C<inject_run_data()>.

=item harness_job_launch

This facet is almost always in the same event as the C<harness_job_start>
facet. I<NOTE:> While writing these docs the author wonders if this facet is
unnecessary...

    {
        stamp => $UNIX_TIMESTAMP,
        rety  => $INTEGER,
    }


=item harness_job_queued

This data is produced by the C<queue_item> method in
L<Test2::Harness::TestFile>.

This contains the data about a test job conveyed by the queue. This usually
contains data that will later be used by L<Test2::Harness::Runner::Job>. It is
better to use the C<harness_job> facet, which contains the final data used to
run the job.

The following 3 fields are the only ones likely to be useful to most people:

    {
        file   => $ORIGINAL_PATH_TO_FILE,
        job_id => $UUID_OR_STRING,
        stamp  => $UNIX_TIMESTAMP,
    }

=item harness_job_start

This facet is sent in an event as soon as a job starts. The data in this facet
is mainly intended to convey necessary information to a renderer so that it can
render the fact that a job started.

    {
        file     => $provided_path_to_test_file,
        rel_file => $relative_path_to_test_file,
        abs_file => $absolute_path_to_test_file,

        stamp => $UNIX_TIMESTAMP,  # Timestamp of when the test completed
        job_id => $UUID_OR_STRING,

        details => "Job UUID_OR_STRING started at $UNIX_TIMESTAMP",
    }

=item harness_run

A hash representation of an L<Test2::Harness::Run> object.

=back

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
