package Test2::Harness2::Resource::PipeLimits;
use strict;
use warnings;

# Implementation note: this resource accepts a --utilize percentage; the
# gating mechanism is wired up in a follow-up step.

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <headroom
    <warn_threshold
    <poll_interval
    <utilize_percent
    +_warned
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

sub resource_name { 'pipe_limits' }

sub init {
    my $self = shift;

    # How much slack to leave at the user's soft pipe-count limit. When
    # available - in_use <= headroom, available() returns 0 and new
    # assignments stall until pressure eases.
    $self->{+HEADROOM} //= 32;

    # Fraction of the soft limit at which the user-facing one-shot
    # warning fires. Crosses once: if usage drops back below and
    # later climbs back, the warning does NOT re-fire (per spec:
    # "warn only once").
    $self->{+WARN_THRESHOLD} //= 0.85;

    $self->{+POLL_INTERVAL} //= 2;

    # Sticky one-shot flag for the warning. Initialised to 0; flipped
    # to 1 the first time live usage crosses warn_threshold * limit.
    # Survives subsequent samples; the resource never warns again
    # for the lifetime of this object.
    $self->{+_WARNED} //= 0;
}

# STUB: throttles new test launches when the user is close to their
# soft pipe-count limit, and emits a one-shot warning so the user
# knows to raise the limit (or kill whatever is hoarding pipes)
# before the throttle bites further runs.
#
# Why a separate resource from UnixLimits:
# Per-process pipe count is not directly an rlimit on most platforms.
# Linux exposes it via /proc/sys/fs/pipe-user-pages-{soft,hard}
# (system-wide, not rlimit-style); macOS / BSD impose it indirectly
# via RLIMIT_NOFILE and per-pipe file-descriptor cost. Tracking pipe
# count specifically -- not just open FDs -- needs its own sampler
# because the harness opens a *lot* of pipes per concurrent test
# (collector stdout/stderr capture, EventEmitter sync, IPC client
# socketpairs, ...) and a pipe-count cap can fire well before
# RLIMIT_NOFILE does.
#
# Scope:
# - Unix-family platforms only (Linux, the BSD variants, macOS,
#   Solaris / illumos). Windows is out of scope -- the pipe-allocation
#   accounting differs enough that it is a separate problem.
#
# Sampling sources by platform (suggested platform-specific
# subclasses, mirroring the UnixLimits.pm split):
#
# - Linux:
#     - Soft cap: read /proc/sys/fs/pipe-user-pages-soft.
#     - Live usage: walk /proc/<our-pid-tree>/fd looking for "pipe:..."
#       symlinks; or aggregate /proc/<pid>/fdinfo for kind=pipe.
#       cgroup v2 io.max may layer on top in modern systemd user
#       sessions -- worth respecting when present.
# - BSD (FreeBSD / OpenBSD / NetBSD / DragonFly):
#     - Soft cap: sysctl kern.ipc.maxpipekva (system-wide page budget,
#       not strictly per-user, but the closest analog).
#     - Live usage: kinfo_getfile / libprocstat for per-process pipe
#       FDs; then sum across our managed pid tree.
# - macOS (Darwin): proc_pidinfo + PROC_PIDLISTFDS, filter for
#     PROX_FDTYPE_PIPE.
# - Solaris / illumos: prctl(2) doesn't expose a pipe rlimit per se;
#     fall back to RLIMIT_NOFILE accounting plus /proc/<pid>/fd kind
#     filtering, and treat the soft cap as
#     min(RLIMIT_NOFILE, sysconf(_SC_OPEN_MAX)).
#
# Intended implementation shape:
# 1. A `service_pipe_limits_monitor` child runs in the background
#    polling every poll_interval seconds for (soft_limit, in_use).
#    The monitor IPCs the latest sample to this resource.
# 2. available(%p) computes
#        free = soft_limit - in_use - headroom
#    and returns 0 when free < the job's pipe-cost estimate
#    (typically 4-6 pipes per concurrent test: 2 for the collector
#    stdout/stderr capture pair, 1-2 for EventEmitter sync, 1-2 for
#    IPC client socketpairs). When 0, log throttling once per
#    transition into "throttled" -- not every poll.
# 3. assign / release track per-assignment estimates against
#    in_use_in_flight; the next monitor sample is authoritative.
# 4. After each sample the resource checks
#        in_use >= warn_threshold * soft_limit
#    If that's true and _WARNED is 0, emit a single warning event
#    naming the soft limit, current usage, and the suggested action
#    (raise pipe-user-pages-soft on Linux, etc.). Set _WARNED = 1
#    so the warning never re-fires for this resource instance.
#    The warning goes out via emit_resource_warning (analogous to
#    the existing diag/warn pattern in Disk / Memory) so the
#    renderer can surface it once at the user.
# 5. teardown() is a no-op beyond stopping the monitor service.
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
        resource       => $self->resource_name,
        headroom       => $self->{+HEADROOM},
        warn_threshold => $self->{+WARN_THRESHOLD},
        poll_interval  => $self->{+POLL_INTERVAL},
        warned         => $self->{+_WARNED},
        broken         => $self->is_broken,
        paused         => $self->is_paused,
        permanent      => $self->is_permanent_broken,
        assignments    => [],
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::PipeLimits - (STUB) Throttle jobs and warn once when close to the user's soft pipe limit.

=head1 STATUS

Stub only. Placeholder for a resource that:

=over 4

=item *

Throttles new job launches (C<available> returns 0) when the user's
soft pipe-count limit minus current usage drops below C<headroom>.

=item *

Emits exactly one user-facing warning the first time usage crosses
C<warn_threshold * soft_limit>, advising the user to raise the
limit or release pipes before the throttle bites. The warning is
sticky -- it never re-fires for the lifetime of this resource
instance, even if usage briefly drops and climbs again.

=back

Intended to support Linux, the BSD variants (FreeBSD / OpenBSD /
NetBSD / DragonFly / macOS), and Solaris / illumos. Each platform's
sampler is a candidate for a dedicated subclass (e.g.
L<Test2::Harness2::Resource::PipeLimits::Linux>,
L<Test2::Harness2::Resource::PipeLimits::BSD>,
L<Test2::Harness2::Resource::PipeLimits::Solaris>) that plugs into
this base class's scheduling contract.

Windows and other non-Unix platforms are explicitly out of scope
for this resource; pipe-allocation accounting on Win32 is
sufficiently different that it deserves its own implementation
rather than a shoehorned subclass here.

=head1 ATTRIBUTES

=over 4

=item headroom

Pipes to leave free under the soft limit. C<available()> returns 0
when C<soft_limit - in_use <= headroom>. Default: C<32>.

=item warn_threshold

Fraction of the soft limit at which the one-shot warning fires.
Default: C<0.85> (warn at 85% usage).

=item poll_interval

Seconds between samples of (soft_limit, in_use). Default: C<2>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Resource::UnixLimits> -- sibling stub for
RLIMIT_NPROC / RLIMIT_NOFILE throttling. PipeLimits exists separately
because per-process pipe count is not exposed as an rlimit on most
platforms and needs its own platform-specific sampler.

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
