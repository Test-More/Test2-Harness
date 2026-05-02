package Test2::Harness2::Resource::Memory;
use strict;
use warnings;

# Implementation note: this resource accepts a --utilize percentage; the
# gating mechanism is wired up in a follow-up step.
#
# History-aware TODO (Phase 6.6): when this resource is implemented
# the sampler should also consult the most recent log -- and, once
# they exist, App::Yath2DB / App::Yath2UI history -- for per-test
# memory usage. The decision "is it safe to start this test now given
# current free memory?" benefits from the historical high-water mark
# of the test, not just the live system sample. App::Yath2DB and
# App::Yath2UI are both optional; this resource must continue to
# work (using only the live sample) when neither is installed.

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <min_free_mb
    <poll_interval
    <utilize_percent
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

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

# Utilizer role contract; wired up alongside the sampler in a
# follow-up step.
sub set_utilize_percent {
    croak __PACKAGE__ . "::set_utilize_percent is not implemented yet";
}

sub is_temporarily_unavailable {
    croak __PACKAGE__ . "::is_temporarily_unavailable is not implemented yet";
}

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
