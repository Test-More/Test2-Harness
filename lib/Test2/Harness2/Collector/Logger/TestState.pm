package Test2::Harness2::Collector::Logger::TestState;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/weaken/;

use Object::HashBase qw{
    <ipcm_info
    <peer
    <run_id
    <job_id
    <job_try
    <test_file
    <test_file_abs
    <auditor
    <loggers_lookup
    <log_file
    +handle
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

use constant JSONL_CLASS => 'Test2::Harness2::Collector::Logger::JSONL';

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    croak "'peer' is a required attribute"
        unless defined $self->{+PEER};

    croak "'job_id' is a required attribute"
        unless defined $self->{+JOB_ID};

    $self->{+JOB_TRY} //= 0;

    # If loggers_lookup came in via the constructor, weaken it the same way
    # set_loggers_lookup() would, so the cycle through the lookup hash back
    # to this logger does not anchor the logger's own refcount.
    weaken($self->{+LOGGERS_LOOKUP}) if defined $self->{+LOGGERS_LOOKUP};
}

# TestState narrates a single test job: startup announces test_started,
# shutdown reports test_completed with auditor-derived counts. It has no
# useful role on service-level collectors, which have no auditor and no
# single test to narrate -- skip it there.
sub applicable {
    my ($class_or_self, $collector) = @_;
    return $collector && $collector->auditor ? 1 : 0;
}

# Fire-and-forget messages to an IPC peer. log_events is intentionally false
# so log_event is never called: per-subtest announcements flow from the
# auditor, which emits synthetic harness.subtest_started events that get
# written to the JSONL log; anything reading the log sees them there.
sub log_events { 0 }

# metadata() inherited default is undef: messages to the peer are transient;
# nothing to retrieve from this logger after the fact.

sub set_auditor {
    my ($self, $auditor) = @_;
    $self->{+AUDITOR} = $auditor;
    return;
}

sub set_loggers_lookup {
    my ($self, $lookup) = @_;
    $self->{+LOGGERS_LOOKUP} = $lookup;

    # The lookup hash contains this very logger among its entries. Weaken
    # our copy so the cycle (collector -> lookup -> logger -> lookup) is
    # broken and the loggers can be freed normally when the collector is.
    weaken($self->{+LOGGERS_LOOKUP});

    return;
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

sub startup {
    my $self = shift;

    croak __PACKAGE__ . " requires an auditor"
        unless $self->{+AUDITOR};

    # JSONL is optional -- if more than one is configured use the first.
    my $lookup = $self->{+LOGGERS_LOOKUP} // {};
    if (my $jsonls = $lookup->{+JSONL_CLASS}) {
        if (my $jsonl = $jsonls->[0]) {
            $self->{+LOG_FILE} = $jsonl->output_file;
        }
    }

    $self->_send({
        kind          => 'test_started',
        test_file     => $self->{+TEST_FILE},
        test_file_abs => $self->{+TEST_FILE_ABS},
        log_file      => $self->{+LOG_FILE},
    });
}

# Called once by the collector when the auditor first transitions from
# passing to failing.
sub failing {
    my $self = shift;
    $self->_send({kind => 'test_failing'});
    return;
}

sub shutdown {
    my $self = shift;

    my $auditor = $self->{+AUDITOR} or return;

    my $exit = $auditor->has_exit ? $auditor->exit : undef;

    $self->_send({
        kind             => 'test_completed',
        test_file        => $self->{+TEST_FILE},
        test_file_abs    => $self->{+TEST_FILE_ABS},
        log_file         => $self->{+LOG_FILE},
        pass_count       => $auditor->pass_count,
        fail_count       => $auditor->fail_count,
        assertion_count  => $auditor->assertion_count,
        passing_subtests => $auditor->passing_subtests // [],
        failing_subtests => $auditor->failing_subtests // [],
        exit             => $exit,
    });

    return;
}

sub _send {
    my ($self, $payload) = @_;

    $payload->{run_id}  = $self->{+RUN_ID}  if defined $self->{+RUN_ID};
    $payload->{job_id}  = $self->{+JOB_ID}  if defined $self->{+JOB_ID};
    $payload->{job_try} = $self->{+JOB_TRY} if defined $self->{+JOB_TRY};

    my $ok = eval {
        unless ($self->{+HANDLE}) {
            require IPC::Manager::Service::Handle;
            $self->{+HANDLE} = IPC::Manager::Service::Handle->new(
                service_name => $self->{+PEER},
                ipcm_info    => $self->{+IPCM_INFO},
                (defined $self->{+JOB_ID} ? (name => $self->{+JOB_ID}) : ()),
            );
        }

        $self->{+HANDLE}->client->send_message($self->{+PEER}, $payload);
        1;
    };
    warn __PACKAGE__ . " send failed: $@" unless $ok;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::TestState - Push lifecycle events from a
test collector to an IPC peer.

=head1 DESCRIPTION

A collector logger that narrates a test run to an IPC peer (typically a UI
or monitoring service). It sends short fire-and-forget messages over the
C<send_message> primitive of L<IPC::Manager::Service::Handle>, so the
collector's shutdown path is never blocked.

This logger is B<not> enabled by default; it must be requested explicitly
via the collector's C<loggers> spec. It is optionally paired with
L<Test2::Harness2::Collector::Logger::JSONL> -- when JSONL is present the
path of its log file is included in the IPC messages so the peer knows
where to look for the full per-event stream. Without JSONL the C<log_file>
field on each message is C<undef>.

The logger does B<not> implement C<log_event>: it only acts at lifecycle
boundaries (C<startup>, C<failing>, C<shutdown>). Per-subtest announcements
flow through the auditor, which emits synthetic C<harness.subtest_started>
events into the pipeline; JSONL writes those to the log and any consumer
that wants them can read them back from there.

=head1 MESSAGES

Every message is a hashref with a C<kind> field plus C<run_id>, C<job_id>,
and C<job_try> when defined on the logger.

=over 4

=item test_started

    { kind => 'test_started', test_file => ..., test_file_abs => ..., log_file => ... }

Sent from C<startup>. C<log_file> is C<undef> when no JSONL logger is
configured.

=item test_failing

    { kind => 'test_failing' }

Sent once, the first time the auditor transitions from passing to failing.

=item test_completed

    {
        kind             => 'test_completed',
        test_file        => ...,
        test_file_abs    => ...,
        log_file         => ...,
        pass_count       => $auditor->pass_count,
        fail_count       => $auditor->fail_count,
        assertion_count  => $auditor->assertion_count,
        passing_subtests => $auditor->passing_subtests,
        failing_subtests => $auditor->failing_subtests,
        exit             => $auditor->has_exit ? $auditor->exit : undef,
    }

Sent from C<shutdown> once the test has finished and the auditor has seen
the exit event.

=back

=head1 ATTRIBUTES

=over 4

=item ipcm_info (required)

L<IPC::Manager> route info for reaching the peer.

=item peer (required)

Service name of the IPC peer to send messages to.

=item test_file / test_file_abs

Relative and absolute paths to the test file, echoed back in the start and
completed messages. Both are optional; callers that have the info on hand
(e.g. the harness service) should pass them through.

=item run_id / job_id / job_try

Stamped onto every message when defined.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
