package Test2::Harness2::Role::Resource::Utilizer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Role::Tiny;

# The role layers two responsibilities on top of the base resource
# contract:
#
# 1. A `utilize_percent` attribute -- the threshold (0 < pct < 100) at
#    which the resource considers its monitored subsystem
#    "saturated". The base class does not know how to read CPU load,
#    free memory, /tmp space, etc.; each consumer wires its own
#    sampler and compares against this threshold.
# 2. A `temporarily_unavailable` predicate the scheduler consults
#    before calling `available`. When true, the resource defers new
#    assignments until the next sample shows the subsystem has eased
#    back below the threshold.
#
# Both the threshold setter and the predicate are required. Consumers
# that have not implemented their per-subsystem sampler yet should
# stub them with a `croak` that names the method, matching the
# existing Disk / Memory / PipeLimits / UnixLimits stub style.

requires 'set_utilize_percent';
requires 'is_temporarily_unavailable';

# Read-only accessor for the configured threshold. Consumers that
# store the value somewhere other than $self->{utilize_percent} should
# override this to match their HashBase slot. The base implementation
# pulls from the attribute the role advertises in its documentation.
sub utilize_percent { $_[0]->{utilize_percent} }

# Validate-and-set helper that consumers may call from their own
# `set_utilize_percent` override. Centralises the
# 0 < pct < 100 contract so every utilizer enforces the same range
# (mirroring the App::Yath2::Options::Resource `--utilize` validation).
sub _validate_utilize_percent {
    my ($self, $pct) = @_;

    croak ref($self) . "::set_utilize_percent requires a numeric percentage"
        unless defined $pct && $pct =~ m/^[0-9]+(?:\.[0-9]+)?\z/;

    croak ref($self) . "::set_utilize_percent percentage must be > 0 and < 100 (got '$pct')"
        unless $pct > 0 && $pct < 100;

    return $pct;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource::Utilizer - Utilization-aware resource role.

=head1 STATUS

The role contract is defined. Per-resource implementations are stubs;
each utilization-aware resource (Memory, PipeLimits, UnixLimits,
TempSpace, CPU) consumes the role and croaks from its required
methods until the platform-specific sampler is wired up.

=head1 DESCRIPTION

This role layers utilization-aware behaviour on top of
L<Test2::Harness2::Role::Resource>. A consumer of both roles is a
resource that:

=over 4

=item *

Implements the base resource contract (C<available>, C<assign>,
C<release>, C<status>).

=item *

Accepts a percentage threshold (0 < pct < 100) describing how heavily
loaded its monitored subsystem -- CPU load, free memory, free C</tmp>
space, etc. -- is allowed to be before the resource starts deferring
new assignments.

=item *

Exposes a C<is_temporarily_unavailable> predicate the scheduler
checks before C<available>. When the predicate returns true the
resource is treated as transiently unusable; the scheduler skips
C<assign> for this tick and re-tries on the next one.

=back

The role does B<not> alter the base contract. Resources that consume
both roles still go through the same scheduler walk:

    needed -> is_permanent_broken -> is_usable
           -> is_temporarily_unavailable
           -> available -> assign

The new step folds in between the existing C<is_usable> check and the
C<available> call, so a utilizer-aware resource with a saturated
subsystem looks identical (to the scheduler) to a transiently-broken
one: defer this tick, retry next.

=head1 REQUIRED METHODS

Consumers must implement these. C<requires> applies to each.

=over 4

=item $resource->set_utilize_percent($pct)

Receives the percentage from C<--utilize> / C<-U>. Must validate via
C<_validate_utilize_percent> (provided below) or its own equivalent
range check (0 < pct < 100), store the value, and arrange for the
sampler / monitor service to consult it on subsequent samples.

Stub implementations in resources that do not yet have a sampler
should C<croak> with a clear "not implemented" message.

=item $bool = $resource->is_temporarily_unavailable

Return true when the resource's monitored subsystem is currently
above the configured threshold, false otherwise. Called by the
scheduler immediately after C<is_usable>; saturated resources are
deferred (the scheduler does not call C<available> or C<assign> on
them this tick).

Resources that can never be saturated (or that lack a sampler) should
C<croak> from this method until they are implemented; calling
C<is_temporarily_unavailable> on a not-yet-wired utilizer is a
contract violation, not a silent C<0>.

=back

=head1 PROVIDED METHODS

=over 4

=item $pct = $resource->utilize_percent

Read-only accessor for the configured threshold. The default
implementation reads C<$self-E<gt>{utilize_percent}>; consumers that
store the value elsewhere (e.g. under a HashBase-named constant)
should override.

=item $pct = $resource->_validate_utilize_percent($pct)

Helper for use inside an implementation's C<set_utilize_percent>.
Validates that C<$pct> is numeric and strictly between C<0> and
C<100>; croaks otherwise. Returns the validated value so the caller
can store it directly:

    sub set_utilize_percent {
        my ($self, $pct) = @_;
        $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
        return;
    }

=back

=head1 SPAWN-THROTTLE WINDOW

The percentage gate is paired with a spawn-throttle window so the
system has time to actually consume newly spawned tests' resources
before more tests are launched against an apparently-idle sample.

=over 4

=item *

The harness tracks, in a sliding 2-second window, the count of
C<(spawned - exited)>.

=item *

When the delta is at or above a per-class threshold the harness
waits one more second before starting the next batch.

=item *

If 40 spawn and 40 exit in the same 2 seconds (delta C<0>), no
throttling occurs.

=back

The window is implemented at the harness layer; per-resource code
exposes its threshold via the role's status hash and otherwise stays
out of the way.

=head1 SEE ALSO

L<Test2::Harness2::Role::Resource> -- the base resource contract.

L<App::Yath2::Options::Resource> -- the C<--utilize> / C<-U> option
that supplies the percentage threshold.

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
