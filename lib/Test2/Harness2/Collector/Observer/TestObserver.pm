package Test2::Harness2::Collector::Observer::TestObserver;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use List::Util qw/first/;
use Time::HiRes qw/time/;

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Observer';

use Object::HashBase qw{
    <run_id
    <job_id
    <job_try
    <ipcm_info
    <auditor

    +_collector
    +_ipc_run
    +_ipc_harness
    +_bus_id
    +_test_pid
    +_collector_pid

    +_emitted_started
    +_emitted_diagnosing
    +_emitted_failing
    +_emitted_completed
};

sub init {
    my $self = shift;

    croak "'job_id' is a required attribute" unless defined $self->{+JOB_ID};

    $self->{+JOB_TRY} //= 0;
}

sub set_process_info {
    my ($self, %info) = @_;
    $self->{+RUN_ID}  = $info{run_id}  if exists $info{run_id};
    $self->{+JOB_ID}  = $info{job_id}  if exists $info{job_id};
    $self->{+JOB_TRY} = $info{job_try} if exists $info{job_try};
    return;
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

sub set_auditor {
    my ($self, $auditor) = @_;
    $self->{+AUDITOR} = $auditor;
    return;
}

# startup() captures collector-level addressing, pids, and the auditor
# so observe_event can emit IPC without reaching back through the
# collector for each message. The collector is the authoritative source
# of ipc_run / ipc_harness / bus_id because those are tied to its
# position in the service tree, not the observer's, and ipc_run is
# what we need most -- every test_job_* message targets the run
# service. Also emits test_job_started immediately so the run service
# learns about a new running job as soon as the collector exists,
# without waiting for the first parsed event.
sub startup {
    my ($self, $collector) = @_;

    $self->{+_COLLECTOR}     = $collector;
    $self->{+_IPC_RUN}       = $collector->ipc_run;
    $self->{+_IPC_HARNESS}   = $collector->ipc_harness;
    $self->{+_BUS_ID}        = $collector->bus_id;
    $self->{+_TEST_PID}      = $collector->child_pid;
    $self->{+_COLLECTOR_PID} = $$;
    $self->{+AUDITOR} //= $collector->auditor;

    $self->_emit_started;

    return;
}

# Per-event side effects. Pass the incoming event through
# unchanged; the only output this observer produces is IPC traffic
# fired at specific stream transitions (first failure, first
# diagnostic, post-reap completion).
sub observe_event {
    my ($self, $event) = @_;

    my $f = $event->facet_data;
    return ($event) unless $f;

    # Final-verdict trigger. Auditor adds harness_job_exit post-reap
    # (synthesized from harness_process_exit). That event is also the
    # final event in the stream, so by the time we see it the auditor
    # has finished counting and the payload we build here reflects
    # its final state.
    if (!$self->{+_EMITTED_COMPLETED} && $f->{harness_job_exit}) {
        $self->_emit_completed($f->{harness_job_exit});
        return ($event);
    }

    unless ($self->{+_EMITTED_FAILING}) {
        $self->_emit_failing if $self->_event_is_failing($f);
    }

    unless ($self->{+_EMITTED_DIAGNOSING}) {
        $self->_emit_diagnosing if $self->_event_is_diagnostic($f);
    }

    return ($event);
}

sub _event_is_failing {
    my ($self, $f) = @_;

    if (my $assert = $f->{assert}) {
        return 1 if !$assert->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
    }

    if (my $errors = $f->{errors}) {
        return 1 if first { $_->{fail} } @$errors;
    }

    if (my $ctrl = $f->{control}) {
        return 1 if $ctrl->{halt} || $ctrl->{terminate};
    }

    return 0;
}

sub _event_is_diagnostic {
    my ($self, $f) = @_;

    if (my $from = $f->{from_stream}) {
        return 1 if defined($from->{source}) && $from->{source} eq 'STDERR';
    }

    if (my $info = $f->{info}) {
        return 1 if first { $_->{important} || $_->{debug} } @$info;
    }

    return 0;
}

sub _send_to_run {
    my ($self, $content) = @_;
    my $target    = $self->{+_IPC_RUN}   or return;
    my $collector = $self->{+_COLLECTOR} or return;
    $collector->send_ipc($target, $content);
    return;
}

sub _send_to_harness {
    my ($self, $content) = @_;
    my $target    = $self->{+_IPC_HARNESS} or return;
    my $collector = $self->{+_COLLECTOR}   or return;
    $collector->send_ipc($target, $content);
    return;
}

sub _base_payload {
    my $self = shift;
    return (
        run_id  => $self->{+RUN_ID},
        job_id  => $self->{+JOB_ID},
        job_try => $self->{+JOB_TRY},
        stamp   => time,
    );
}

sub _emit_started {
    my $self = shift;
    return if $self->{+_EMITTED_STARTED};
    $self->{+_EMITTED_STARTED} = 1;

    $self->_send_to_run({
        kind => 'test_job_started',
        $self->_base_payload,
        collector_pid => $self->{+_COLLECTOR_PID},
        test_pid      => $self->{+_TEST_PID},
    });
}

sub _emit_diagnosing {
    my $self = shift;
    return if $self->{+_EMITTED_DIAGNOSING};
    $self->{+_EMITTED_DIAGNOSING} = 1;

    $self->_send_to_run({
        kind => 'test_job_diagnosing',
        $self->_base_payload,
    });
}

sub _emit_failing {
    my $self = shift;
    return if $self->{+_EMITTED_FAILING};
    $self->{+_EMITTED_FAILING} = 1;

    $self->_send_to_run({
        kind => 'test_job_failing',
        $self->_base_payload,
    });
}

sub _emit_completed {
    my ($self, $exit_facet) = @_;
    return if $self->{+_EMITTED_COMPLETED};
    $self->{+_EMITTED_COMPLETED} = 1;

    my $auditor = $self->{+AUDITOR};

    my %payload = (
        kind => 'test_job_completed',
        $self->_base_payload,
        exit  => $exit_facet->{exit},
        codes => $exit_facet->{codes},
    );

    if ($auditor) {
        $payload{pass}       = $auditor->pass ? 1 : 0 if $auditor->can('pass');
        $payload{pass_count} = $auditor->pass_count   if $auditor->can('pass_count');
        $payload{fail_count} = $auditor->fail_count   if $auditor->can('fail_count');
    }

    $payload{times}       = $exit_facet->{times}       if $exit_facet->{times};
    $payload{child_times} = $exit_facet->{child_times} if $exit_facet->{child_times};
    $payload{child_wall}  = $exit_facet->{child_wall}  if defined $exit_facet->{child_wall};

    $self->_send_to_run(\%payload);

    $self->_send_to_harness({
        kind   => 'job_release',
        run_id => $self->{+RUN_ID},
        job_id => $self->{+JOB_ID},
        stamp  => $payload{stamp},
    });

    return;
}

sub shutdown {
    my ($self, $collector) = @_;
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Observer::TestObserver - Observer for
test-job collectors that emits run-service / harness IPC messages on
key stream transitions.

=head1 DESCRIPTION

Installed by default on test-job collectors. Watches the post-auditor
event stream and, when conditions defined in the run-service
aggregation design are met, emits IPC messages:

=over 4

=item C<test_job_started>

Sent to the run service as soon as the collector is up and has the
test process pid. Payload includes C<run_id>, C<job_id>, collector
pid, and test pid.

=item C<test_job_diagnosing>

Sent to the run service the first time a diagnostic event is seen
(Info facet with C<important> or C<debug> set, or a STDERR line).

=item C<test_job_failing>

Sent to the run service the first time a failing assertion or error
facet is seen.

=item C<test_job_completed>

Sent to the run service once the test process has been reaped (i.e.
once a C<harness_job_exit> facet surfaces). Payload carries the final
auditor result (pass/fail, counts) and the raw exit / parsed codes.

=item C<job_release>

Sent to the harness at the same time as C<test_job_completed>.
Agnostic to outcome: tells the scheduler the job is no longer holding
resources so it can advance the queue. Payload: C<run_id> and
C<job_id> only -- the harness looks up held resources from its own
bookkeeping.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
