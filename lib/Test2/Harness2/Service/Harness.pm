package Test2::Harness2::Service::Harness;
use v5.38;

our $VERSION = '2.000000';

use Config       qw/%Config/;
use File::Spec   ();
use File::Path   qw/make_path/;

use Test2::Harness2::Collector qw/spawn_collector/;
use Test2::Harness2::Collector::Recorder::Test;
use Test2::Harness2::Collector::Monitor;
use Test2::Harness2::Scheduler;

use Object::HashBase qw{
    <workdir
    <name
    <scheduler
    <monitor
    <running
    <run_stray
    <client_seq
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Service::Harness - The main harness service.

=head1 DESCRIPTION

The global harness service. It consumes L<Test2::Harness2::Role::Service> for its
request loop, owns a L<Test2::Harness2::Scheduler> and a managed
L<Test2::Harness2::Collector::Monitor>, accepts requests from clients to queue
runs, launches each test job under a collector (fork + exec), and forwards
collector state updates to any subscribed client.

Initial version: one run and one job at a time, fork+exec launch, no resources
or retries.

=head1 REQUESTS

=over 4

=item queue_run => { files => [...], run_uuid?, stray? }

Queue a run; returns C<< {ok, run_uuid, run_ord, job_uuids} >>.

=item no_more_runs

Declare no further runs; the service stops once everything finishes.

=item subscribe

Register the requesting connection to receive collector transition frames
(forwarded by the monitor). Returns C<< {ok, monitor => $path} >>.

=back

=cut

sub init ($self) {
    $self->{+NAME}       //= 'harness';
    $self->{+SCHEDULER}  //= Test2::Harness2::Scheduler->new;
    $self->{+MONITOR}    //= Test2::Harness2::Collector::Monitor->new(listen => 1);
    $self->{+RUNNING}    //= {};
    $self->{+RUN_STRAY}  //= {};
    $self->{+CLIENT_SEQ} //= 0;

    die "'workdir' is required\n" unless defined $self->{+WORKDIR} && length $self->{+WORKDIR};
    make_path($self->{+WORKDIR}) unless -d $self->{+WORKDIR};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $self->service_tick

Called each loop iteration: poll the monitor, mark finished jobs done, launch
pending jobs, and stop the service once the scheduler reports everything done.

=back

=cut

sub service_tick ($self) {
    my $mon = $self->{+MONITOR};
    $mon->poll;

    # Mark a job done only once its collector is finalized: by then the monitor
    # has already forwarded the job's final_state frame to subscribers, so we
    # will not stop the service out from under a client still reading it.
    for my $job_uuid ($mon->new_finalized) {
        my $entry = delete $self->{+RUNNING}{$job_uuid} or next;
        $self->{+SCHEDULER}->mark_done($entry->{job});
    }

    # Launch as many pending jobs as the scheduler allows.
    while (my $job = $self->{+SCHEDULER}->next_job) {
        $self->_launch_job($job);
    }

    $self->stop_service if $self->{+SCHEDULER}->all_done;

    return;
}

=over 4

=item $resp = $self->request_handler_queue_run($payload)

=item $resp = $self->request_handler_no_more_runs($payload)

=item $resp = $self->request_handler_subscribe($payload, $conn)

Request handlers; see L</REQUESTS>.

=back

=cut

sub request_handler_queue_run ($self, $payload, $conn = undef) {
    my $files = $payload->{files};
    return {ok => 0, error => "'files' must be a non-empty arrayref"}
        unless ref($files) eq 'ARRAY' && @$files;

    my $run = $self->{+SCHEDULER}->queue_run(
        files => $files,
        (defined $payload->{run_uuid}  ? (run_uuid  => $payload->{run_uuid})  : ()),
        (defined $payload->{job_uuids} ? (job_uuids => $payload->{job_uuids}) : ()),
    );

    $self->{+RUN_STRAY}{$run->{run_uuid}} = $payload->{stray} ? 1 : 0;

    return {
        ok       => 1,
        run_uuid => $run->{run_uuid},
        run_ord  => $run->{run_ord},
        job_uuids => [map { $_->{job_uuid} } @{$run->{jobs}}],
    };
}

sub request_handler_no_more_runs ($self, $payload = undef, $conn = undef) {
    $self->{+SCHEDULER}->no_more_runs;
    return {ok => 1};
}

sub request_handler_subscribe ($self, $payload, $conn) {
    my $name = 'client-' . $self->{+CLIENT_SEQ}++;
    $self->{+MONITOR}->add_proxy($name, $conn);
    return {ok => 1, monitor => $self->{+MONITOR}->socket_path};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_launch_job($job)

Fork + exec a collector running the job's test file, recording to the job's
events file and reporting transitions to the monitor. Marks the job running.

=item $path = $self->_job_events_file($job)

The job's events file: C<< $workdir/$run_ord/$job_ord/$try.jsonl.zst >> (dirs
created).

=back

=cut

sub _launch_job ($self, $job) {
    my $run      = $job->{run};
    my $events   = $self->_job_events_file($job);
    my $stray    = $self->{+RUN_STRAY}{$run->{run_uuid}} ? 1 : 0;
    my $perl5lib = join($Config{path_sep} || ':', grep { defined && length } @INC, $ENV{PERL5LIB});

    my $pid = spawn_collector(
        is_test   => 1,
        name      => $job->{file},
        uuid      => $job->{job_uuid},
        run_uuid  => $run->{run_uuid},
        exec      => [$^X, $job->{file}],
        env       => {PERL5LIB => $perl5lib},
        processor => [
            ['Test2::Harness2::Collector::Assembler', emit_stray => $stray],
            'Test2::Harness2::Collector::Auditor',
        ],
        recorder => Test2::Harness2::Collector::Recorder::Test->new(
            events_file        => $events,
            transition_sockets => [$self->{+MONITOR}->socket_path],
        ),
    );

    $self->{+SCHEDULER}->mark_running($job);
    $self->{+RUNNING}{$job->{job_uuid}} = {pid => $pid, job => $job, events_file => $events};

    return;
}

sub _job_events_file ($self, $job) {
    my $run = $job->{run};
    my $dir = File::Spec->catdir($self->{+WORKDIR}, $run->{run_ord}, $job->{job_ord});
    make_path($dir) unless -d $dir;
    return File::Spec->catfile($dir, "$job->{try}.jsonl.zst");
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
