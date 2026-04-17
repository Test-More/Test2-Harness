package Test2::Harness2::Collector::Logger::IPCNotify;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util qw/parse_exit/;

use Object::HashBase qw{
    <ipcm_info
    <service_name
    <run_id
    <job_id
    <job_try
    <auditor
    +handle
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

# PURPOSE OF THIS MODULE:
#
# When a test collector exits, this logger sends a test_complete message to the
# harness service. The message carries pass/fail verdict (from the auditor) and
# the child's exit code, and the harness service re-emits it as a structured
# event on its own stdout so its interposed collector's loggers see it
# alongside the service's run_queued/run_ended events.
#
# A secondary effect of sending the message is to WAKE UP the service's IPC
# event loop so the next run_on_all tick happens immediately rather than
# waiting up to ~0.2s for the normal poll interval. We use IPC::Manager's
# fire-and-forget send_message() primitive (not sync_request) because we do
# not need a response and do not want to block the collector's shutdown.
#
# The actual completion is still detected by the existing
# _check_current_completion path on the next loop iteration via
# waitpid(WNOHANG). The message just ensures the loop does not sleep through
# that window, and (new) carries structured pass/exit data for downstream
# loggers.

# Logger role -- applicable only inside a 'test' collector. A service-kind
# collector has no harness service to notify, so the applicable() filter
# drops this spec there.
sub applicable {
    my ($class, $info) = @_;
    my $kind = $info && $info->{kind};
    return 1 if !defined $kind;
    return $kind eq 'test' ? 1 : 0;
}

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    croak "'service_name' is a required attribute" unless defined $self->{+SERVICE_NAME};

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

sub log_events { 0 }

sub shutdown {
    my $self      = shift;
    my ($collector) = @_;

    # Derive pass/fail from the auditor if one is present. Services without
    # an auditor (pipe-only collection) fall through as undef and the
    # downstream logger can treat that as "unknown".
    my $pass;
    if (my $auditor = $self->{+AUDITOR}) {
        $pass = $auditor->failing ? 0 : 1;
    }

    # Exit status from the collector. _CHILD_EXIT is the raw wait-status of
    # the launched test process; parse it into numeric exit code + signal.
    my ($exit_code, $exit_sig);
    if ($collector && defined(my $raw = $collector->{_child_exit})) {
        my $codes = parse_exit($raw);
        $exit_code = $codes->{err};
        $exit_sig  = $codes->{sig};
    }

    my $ok = eval {
        unless ($self->{+HANDLE}) {
            require IPC::Manager::Service::Handle;
            $self->{+HANDLE} = IPC::Manager::Service::Handle->new(
                service_name => $self->{+SERVICE_NAME},
                ipcm_info    => $self->{+IPCM_INFO},
            );
        }

        $self->{+HANDLE}->client->send_message(
            $self->{+SERVICE_NAME},
            {
                kind      => 'test_complete',
                run_id    => $self->{+RUN_ID},
                job_id    => $self->{+JOB_ID},
                job_try   => $self->{+JOB_TRY},
                pass      => $pass,
                exit_code => $exit_code,
                exit_sig  => $exit_sig,
            },
        );

        1;
    };
    warn "IPCNotify shutdown failed: $@" unless $ok;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::IPCNotify - IPC completion notification logger.

=head1 DESCRIPTION

A collector logger that sends a C<test_complete> IPC message to the harness
service when a test finishes. The message carries the pass/fail verdict
(from the auditor, when one is attached) and the child's exit code / signal,
and the harness service re-emits it as a structured C<test_complete> event
on its own stdout so its interposed collector's loggers see it alongside
the service's C<run_queued>/C<run_ended> events.

A secondary effect of sending the message is to B<wake up the service's
event loop> immediately on test completion, so the next C<run_on_all> tick
happens right away rather than waiting up to ~0.2s for the normal poll
interval. We use IPC::Manager's fire-and-forget message primitive (not
C<sync_request>) because we don't need a response and don't want to block
the collector's shutdown path. The actual completion is still detected by
the existing C<_check_current_completion> path on the next loop iteration
via C<waitpid(WNOHANG)>.

The logger is a no-op for individual events; it only acts in C<shutdown()>.
If the IPC notification fails (e.g. because the service is not reachable),
the failure is warned rather than propagated, so the collector's exit path
is never blocked.

The logger's C<applicable()> check returns false for C<kind =E<gt> 'service'>
collector contexts, so including it in a shared logger list is safe -- it
only instantiates in C<'test'> collector contexts where notifying a harness
service actually makes sense.

=head1 SYNOPSIS

    Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL',     output_file => 'out.jsonl'],
            ['Test2::Harness2::Collector::Logger::IPCNotify',
                ipcm_info    => $ipcm_info,
                service_name => 'harness',
                run_id       => $run_id,
                job_id       => $job_id,
            ],
        ],
    );

=head1 ATTRIBUTES

=over 4

=item ipcm_info (required)

IPC::Manager route info for the service.

=item service_name (required)

The name of the service to notify (e.g. C<'harness'>).

=item run_id (required)

The run ID of the test being collected.

=item job_id (required)

The job ID of the test being collected.

=item job_try

The attempt number for this job (defaults to C<0>).

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
