package Test2::Harness2::Resource::Disk;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <mounts
    <poll_interval
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub resource_name { 'disk' }

sub init {
    my $self = shift;

    # mounts is expected to be a hashref of { '/path' => { min_free_mb => $n } }.
    $self->{+MOUNTS}        //= {};
    $self->{+POLL_INTERVAL} //= 5;
}

# STUB: throttles test launches when free disk space on any tracked mount
# drops below its configured threshold. Intended implementation: a
# service_disk_monitor child uses statvfs/df every poll_interval seconds
# and reports per-mount low/ok state back to the harness via IPC.
sub available { croak __PACKAGE__ . "::available is not implemented yet" }
sub assign    { croak __PACKAGE__ . "::assign is not implemented yet" }
sub release   { croak __PACKAGE__ . "::release is not implemented yet" }

sub status {
    my $self = shift;
    return {
        resource    => $self->resource_name,
        mounts      => $self->{+MOUNTS},
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

Test2::Harness2::Resource::Disk - (STUB) Throttle jobs when disk space is low.

=head1 STATUS

Stub only. Placeholder for a resource that prevents new jobs from starting
when free space on a configured mount drops below a threshold.

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
