package Test2::Harness2::Resource::UnixLimits;
use strict;
use warnings;

# Implementation note: this resource accepts a --utilize percentage; the
# gating mechanism is wired up in a follow-up step.

our $VERSION = '2.000011';

use Carp qw/croak/;

use Object::HashBase qw{
    <thresholds
    <poll_interval
    <nofile_headroom
    <nproc_headroom
    <utilize_percent
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';

sub resource_name { 'unix_limits' }

sub init {
    my $self = shift;

    # Per-ulimit headroom: "don't touch these last N units of slack".
    # When current usage + this headroom would meet or exceed the
    # ulimit, available() returns 0 until the next sample shows the
    # pressure has eased.
    $self->{+NOFILE_HEADROOM} //= 64;
    $self->{+NPROC_HEADROOM}  //= 8;
    $self->{+POLL_INTERVAL}   //= 2;

    # thresholds is a hashref of per-limit overrides:
    #   { RLIMIT_NOFILE => { headroom => 128 },
    #     RLIMIT_NPROC  => { headroom => 16  } }
    # Entries here override the simple *_HEADROOM defaults above and
    # are the place to plug in any future rlimits (RLIMIT_AS, etc.).
    $self->{+THRESHOLDS} //= {};
}

# STUB: throttles new test launches when the user's per-process resource
# limits (ulimits) are close to being hit. This is a *preventative*
# brake -- it reads the ulimits we care about, samples our own current
# usage against them, and refuses new assignments (available returns 0)
# when the free margin drops below the configured headroom.
#
# Scope:
# - Unix-family platforms only. No Windows support. Intended to work on
#   Linux, the BSD variants (FreeBSD / OpenBSD / NetBSD / DragonFly /
#   macOS), and Solaris / illumos.
#
# Limits this resource should consider throttling on:
# - RLIMIT_NPROC   -- max user processes. Every concurrent test costs
#                     at minimum one extra process (collector + child
#                     test + any preload stage forks it chained off
#                     of), so NPROC is the most direct cap on "how
#                     many tests we can spawn".
# - RLIMIT_NOFILE  -- max open file descriptors. A leaking test suite,
#                     or one running in the same user session as
#                     long-lived editors / IDEs / browsers, can chew
#                     through the cap quickly. Every collector pipe
#                     pair, every open log file, every test-process
#                     stdio counts against this.
# - (optional, future)
#   RLIMIT_AS / RLIMIT_DATA -- address space. Memory.pm already covers
#                     *system* free memory; the ulimit version would
#                     cover the per-user cap that some sysadmins
#                     impose independently.
#   RLIMIT_CPU / RLIMIT_FSIZE -- probably not worth throttling on,
#                     but they can be added via `thresholds` if a
#                     need appears.
#
# Intended implementation shape:
# 1. A `service_unix_limits_monitor` child runs in the background. It:
#    - Reads the ulimits at start via POSIX::RLIMIT_* + getrlimit()
#      (or BSD::Resource on platforms that need it).
#    - Samples current usage every poll_interval seconds -- see the
#      per-flavour notes below for where that data lives.
#    - Emits IPC updates back to the harness (and transitively this
#      resource) with the current (limit, used, free) triple per
#      tracked rlimit.
# 2. available(%p) consults the latest sampled state. For each tracked
#    rlimit, it computes
#        free = (limit - used) - headroom
#    If any tracked rlimit's free is < the job's estimated cost
#    (NOFILE: test_file->opens_hint or a conservative constant;
#    NPROC: 1 + collector + any additional children the job declares)
#    available returns 0. Otherwise it returns the job's requested
#    grant.
# 3. assign / release track per-assignment estimates so the in-flight
#    accounting stays close to what the next poll will confirm. The
#    poll is authoritative; the bookkeeping only covers the window
#    between spawn and the monitor's next sample.
#
# Per-flavour sampling differs enough that each OS family is a
# reasonable candidate for its own subclass. Suggested split:
#
# - Test2::Harness2::Resource::UnixLimits::Linux
#     - /proc/self/limits for the rlimit values themselves.
#     - /proc/self/fd walk (or /proc/<pid>/fdinfo) for precise NOFILE.
#     - User-process count: /proc scan filtered by UID, or
#       `ps --no-headers -U <uid> -o pid | wc -l`.
#     - cgroup v2 pids.max + pids.current can override RLIMIT_NPROC
#       in modern systemd user sessions -- worth reading when present.
# - Test2::Harness2::Resource::UnixLimits::BSD
#     - FreeBSD / OpenBSD / NetBSD / DragonFly: sysctl(KERN_PROC_*) +
#       kvm_getprocs for the user-process count, kinfo_getfile /
#       libprocstat for FD enumeration.
#     - macOS (Darwin) is BSD-shaped but uses proc_pidinfo /
#       libproc instead of kvm_*. Likely worth its own sub-subclass
#       (UnixLimits::BSD::Darwin) if the divergence gets sharp.
# - Test2::Harness2::Resource::UnixLimits::Solaris
#     - /proc/<pid>/psinfo + prctl(2) for rlimits.
#     - /proc/<pid>/fd for open FD enumeration (same shape as Linux
#       but different record format).
#     - User-process count: pgrep -U <user> | wc -l works as a
#       portable fallback across illumos distributions.
#
# The base class owns the role contract + the generic math; each
# subclass owns the sampler. A small `viable()`-style chooser
# (check $^O and pick the first subclass whose viable() returns
# true, bail out otherwise) keeps the Resource::UnixLimits ->
# platform-impl mapping transparent to the harness config. If no
# subclass is viable the resource should cleanly refuse to start
# rather than load and misreport usage.
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
        resource        => $self->resource_name,
        thresholds      => $self->{+THRESHOLDS},
        nofile_headroom => $self->{+NOFILE_HEADROOM},
        nproc_headroom  => $self->{+NPROC_HEADROOM},
        broken          => $self->is_broken,
        paused          => $self->is_paused,
        permanent       => $self->is_permanent_broken,
        assignments     => [],
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Resource::UnixLimits - (STUB) Throttle jobs against per-user Unix ulimits.

=head1 STATUS

Stub only. Placeholder for a resource that prevents new jobs from starting
when the user's per-process resource limits (RLIMIT_NPROC, RLIMIT_NOFILE,
optionally RLIMIT_AS) are close to being hit.

Intended to support Linux, the BSD variants (FreeBSD / OpenBSD / NetBSD /
DragonFly / macOS), and Solaris / illumos. Each platform's sampler is a
candidate for a dedicated subclass (e.g.
L<Test2::Harness2::Resource::UnixLimits::Linux>,
L<Test2::Harness2::Resource::UnixLimits::BSD>,
L<Test2::Harness2::Resource::UnixLimits::Solaris>) that plugs into this
base class's scheduling contract.

Windows and other non-Unix platforms are explicitly out of scope for this
resource.

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
