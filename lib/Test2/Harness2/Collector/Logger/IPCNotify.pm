package Test2::Harness2::Collector::Logger::IPCNotify;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Test2::Harness2::Util::HashBase qw{
    <ipcm_info
    <service_name
    <run_id
    <job_id
    <job_try
    +handle
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

sub init {
    my $self = shift;

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

sub log_events { 0 }

sub startup { }

sub log_event { }

sub shutdown {
    my $self = shift;

    unless (defined $self->{+IPCM_INFO}) {
        warn "IPCNotify shutdown: ipcm_info not set, skipping notification\n";
        return;
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
                kind    => 'job_complete_notify',
                run_id  => $self->{+RUN_ID},
                job_id  => $self->{+JOB_ID},
                job_try => $self->{+JOB_TRY},
            },
        );

        1;
    };
    warn "IPCNotify shutdown failed: $@" unless $ok;

    return;
}

sub depends_on { () }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::IPCNotify - IPC completion notification logger.

=head1 DESCRIPTION

A collector logger that sends a C<job_complete_notify> IPC request to the
harness service when a test finishes. This wakes the service's event loop
immediately on test completion rather than waiting for the normal poll
interval before the next test is dispatched.

The logger is a no-op for individual events; it only acts in C<shutdown()>.
If the IPC notification fails (e.g. because the service is not reachable),
the failure is warned rather than propagated, so the collector's exit path
is never blocked.

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
