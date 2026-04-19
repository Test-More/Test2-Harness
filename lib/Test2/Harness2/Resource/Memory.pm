package Test2::Harness2::Resource::Memory;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <min_free_mb
    <poll_interval
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub resource_name { 'memory' }

sub init {
    my $self = shift;

    $self->{+MIN_FREE_MB}   //= 512;
    $self->{+POLL_INTERVAL} //= 2;
}

# STUB: throttles new test launches when free system memory drops below
# min_free_mb. Intended implementation: a service_memory_monitor child polls
# /proc/meminfo (or platform equivalent) every poll_interval seconds and
# reports low-memory state back to the harness via IPC. While in a low
# state the resource refuses new assignments (available returns 0).
sub available { croak __PACKAGE__ . "::available is not implemented yet" }
sub assign    { croak __PACKAGE__ . "::assign is not implemented yet" }
sub release   { croak __PACKAGE__ . "::release is not implemented yet" }

sub status {
    my $self = shift;
    return {
        resource    => $self->resource_name,
        min_free_mb => $self->{+MIN_FREE_MB},
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

Test2::Harness2::Resource::Memory - (STUB) Throttle jobs when free memory is low.

=head1 STATUS

Stub only. Placeholder for a resource that prevents new jobs from starting
when available system memory drops below a configured threshold.

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
