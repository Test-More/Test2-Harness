package Test2::Harness2::Role::Subsystem;
use strict;
use warnings;

our $VERSION = '2.000013';

use Scalar::Util qw/weaken/;

use Role::Tiny;

# Role::Subsystem -- shared backref hook for in-process harness collaborators.
#
# Subsystems are plain Object::HashBase objects that the harness constructs
# during its own init and holds a strong reference to. Each subsystem that
# needs to call back into the harness declares a `+harness` HashBase slot
# and consumes this role. The role's `around init` hook weakens that slot
# after the consumer's init runs, so the harness <-> subsystem reference
# pair never forms a cycle.
#
# A no-op default `init` is provided so that consumers with no per-subsystem
# initialization (pure-data holders) can compose the role without having
# to define `init` themselves.

sub init { }

around init => sub {
    my ($orig, $self, @args) = @_;
    $self->$orig(@args);
    my $slot = $self->HARNESS;
    weaken($self->{$slot}) if $self->{$slot};
};

sub harness { $_[0]->{$_[0]->HARNESS} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Subsystem - Shared backref hook for harness subsystems.

=head1 SYNOPSIS

    package Test2::Harness2::PidIndex;
    use strict;
    use warnings;

    use Object::HashBase qw{
        +run_pids
        +harness
    };

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Subsystem';

    sub init {
        my $self = shift;
        $self->{+RUN_PIDS} //= {};
    }

    sub register {
        my ($self, $run_id, $pid) = @_;
        my $h = $self->harness or return;
        # ... use $h ...
    }

    1;

=head1 DESCRIPTION

Subsystems are plain L<Object::HashBase> objects the harness constructs
and holds a strong reference to. Each subsystem that needs to call back
into the harness declares a C<+harness> HashBase slot and consumes this
role.

The role wraps the consumer's C<init> so that after construction the
C<harness> slot is weakened. Combined with the harness holding strong
refs to its subsystems, this avoids a reference cycle without requiring
each subsystem to remember to call C<weaken> itself.

The role tolerates two common shapes:

=over 4

=item Consumers with their own C<init>

The consumer's C<init> runs first (assigning defaults, validating
arguments, etc.); the role then weakens C<+harness> if it was passed.

=item Consumers with no per-subsystem init

The role supplies a no-op default C<init>, so a pure-data subsystem can
compose the role without defining one.

=back

When a subsystem method dereferences C<< $self->harness >> after the
harness has gone out of scope (deferred timer, drained queue, etc.),
the accessor returns C<undef>. Subsystem methods must handle that:

    sub tick {
        my $self = shift;
        my $h = $self->harness or return;
        # ...
    }

=head1 METHODS

=over 4

=item $h = $sub->harness

Returns the harness reference, or C<undef> if the harness has gone away
(weak ref cleared) or was never passed at construction. Equivalent to
C<< $self->{$self->HARNESS} >>.

=back

=cut
