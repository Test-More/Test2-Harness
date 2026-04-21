package Test2::Harness2::Resource::SharedJobs;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <config_file
    <state_file
    <host
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub is_job_limiter { 1 }

sub resource_name { 'sharedjobs' }

# STUB: cross-process / cross-user job slot coordinator. Modeled on the
# old/ and legacy Resource::SharedJobSlots implementation but rewritten for
# the new services model. Intended implementation: a resource service
# (declared via services()) owns the shared state file, grants/releases
# slot reservations to its harness parent via IPC, and honours multiple
# harnesses running on the same host.
sub available { croak __PACKAGE__ . "::available is not implemented yet" }
sub assign    { croak __PACKAGE__ . "::assign is not implemented yet" }
sub release   { croak __PACKAGE__ . "::release is not implemented yet" }

sub status {
    my $self = shift;
    return {
        resource    => $self->resource_name,
        config_file => $self->{+CONFIG_FILE},
        state_file  => $self->{+STATE_FILE},
        host        => $self->{+HOST},
        broken      => $self->is_broken,
        paused      => $self->is_paused,
        permanent   => $self->is_permanent_broken,
        assignments => [],
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::SharedJobs - (STUB) Cross-harness job slot coordinator.

=head1 STATUS

Stub only. Placeholder for the rewrite of the old
C<Test2::Harness2::Resource::SharedJobSlots> module. The reimplementation
is deferred until the services + IPC pieces of the new harness are settled.

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
