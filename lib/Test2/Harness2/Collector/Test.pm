package Test2::Harness2::Collector::Test;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use parent 'Test2::Harness2::Collector';

# Test-job collectors carry an auditor. The auditor slot shadows the
# base class's no-op `auditor` accessor; _auditor_spec holds the
# validated (but not yet instantiated) spec that _instantiate_auditor
# builds inside the collector child process.
use Object::HashBase qw{
    <auditor

    +_auditor_spec
};

# Bus-id derivation for a test-job collector identifies the collector
# by the job_id of the test it is watching. There is no intermediate
# service between the collector and the test process, so ipc_parent
# would not be the right identifier here.
sub _build_collector_bus_id {
    my $self = shift;

    my $job_id = $self->{+JOB_ID}
        or croak "Test collector requires 'job_id' to derive bus_id";

    return $self->_compose_bus_id($job_id);
}

# Validate the auditor spec and stash the original for child-side
# instantiation. Called from Collector::init.
sub _normalize_auditor {
    my $self = shift;

    my $spec = $self->{+AUDITOR};
    return unless defined $spec;

    $self->_validate_spec($spec, 'auditor', 'Test2::Harness2::Role::Auditor');

    $self->{+_AUDITOR_SPEC} = $spec;
}

# Surface the spec for the Windows re-launch path (which serialises
# the spec and hands it to a fresh perl process).
sub _auditor_spec { $_[0]->{+_AUDITOR_SPEC} }

# Build the concrete auditor instance in the collector child process.
# The parent never touches this -- it only carries the spec across
# the fork/spawn boundary.
sub _instantiate_auditor {
    my $self = shift;

    my $spec = $self->{+_AUDITOR_SPEC};
    return unless defined $spec;

    my $inst;
    if (blessed($spec)) {
        $inst = $spec;
        $inst->set_process_info(
            run_id  => $self->{+RUN_ID},
            job_id  => $self->{+JOB_ID},
            job_try => $self->{+JOB_TRY},
        );
        $inst->set_ipcm_info($self->{+IPCM_INFO});
    }
    elsif (ref($spec) eq 'ARRAY') {
        my ($class, @args) = @$spec;
        $inst = $class->new(
            run_id    => $self->{+RUN_ID},
            job_id    => $self->{+JOB_ID},
            job_try   => $self->{+JOB_TRY},
            ipcm_info => $self->{+IPCM_INFO},
            @args,
        );
    }
    else {
        $inst = $spec->new(
            run_id    => $self->{+RUN_ID},
            job_id    => $self->{+JOB_ID},
            job_try   => $self->{+JOB_TRY},
            ipcm_info => $self->{+IPCM_INFO},
        );
    }

    $self->{+AUDITOR} = $inst;
}

# When the test-job collector exits, stamp the auditor's verdict and
# counts onto the harness-bound exit payload.
sub _extend_exiting_payload_for_harness {
    my ($self, $payload) = @_;

    my $auditor = $self->{+AUDITOR};
    return unless ref($auditor) && $auditor->can('pass');

    $payload->{pass}       = $auditor->pass ? 1 : 0;
    $payload->{pass_count} = $auditor->pass_count if $auditor->can('pass_count');
    $payload->{fail_count} = $auditor->fail_count if $auditor->can('fail_count');
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Test - Collector subclass for test-job processes.

=head1 DESCRIPTION

Extends L<Test2::Harness2::Collector> with the test-specific bits:

=over 4

=item *

An C<auditor> that consumes L<Test2::Harness2::Role::Auditor>.

=item *

C<_build_collector_bus_id> pinned to C<collector:E<lt>job_idE<gt>>
(optionally suffixed with C<:run_id>).

=item *

An C<_extend_exiting_payload_for_harness> hook that stamps the
auditor's C<pass> / C<pass_count> / C<fail_count> onto the
C<collector_exiting> payload addressed to the harness.

=back

=head1 SOURCE

L<https://github.com/Test-More/Test2-Harness>

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

See L<https://dev.perl.org/licenses/>

=cut
