package Test2::Harness2::Role::Service;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h getpgrp/;

use Role::Tiny;

use Test2::Harness2::Util qw/tinysleep/;
use Test2::Harness2::Util::IPC qw/list_direct_children/;

use constant IS_WIN32            => $^O eq 'MSWin32';
use constant HAS_CHILD_SUBREAPER => eval {
    require Test2::Harness2::ChildSubReaper;
    Test2::Harness2::ChildSubReaper::have_subreaper_support() ? 1 : 0;
} || 0;

# Any harness-side long-lived service (Test2::Harness2, RunService, a
# future preloader, ...) shares the same skeletal shape: an IPC::Manager
# service, a JSONL/event-bus event stream, a pgroup + optional subreaper
# setup at start, a request_handler_* dispatcher driven by IPC, and a
# uniform TERM-then-KILL escalator at hard-stop. The variable parts are
# what pids the escalator should initially track, what extra fields the
# service_started event carries, and the consumer's own startup work.
# Everything else lives here.

with 'IPC::Manager::Role::Service';

# Consumer contract. Everything else is either provided with a default
# or covered by the IPC::Manager::Role::Service contract below.
requires 'workdir';
requires 'name';
requires 'emit_service_event';
requires 'hard_stop_pids';

# State / policy accessors the role drives. The role reads kill_timeout
# and watch_pids, and writes state / own_pgroup via their setters. A
# typical Object::HashBase consumer gets all of these for free by
# declaring the corresponding slots without a leading-sigil, e.g.
# `state kill_timeout own_pgroup watch_pids`.
requires 'kill_timeout';
requires 'set_state';
requires 'set_own_pgroup';
requires 'watch_pids';

# IPC::Manager::Role::Service contract defaults. All services use
# hash-backed storage, so the role touches $self as a hash safely.
sub orig_io { {} }
sub pid     { $_[0]->{pid} //= $$ }
sub set_pid { $_[0]->{pid} = $_[1] }

# Envelope-aware request dispatcher. Incoming IPC carries a request
# payload under 'request'; the payload is either a scalar (the request
# type) or a hashref with a 'request' key plus any parameters. Route to
# request_handler_<type>() on the consumer.
sub handle_request {
    my ($self, $req, $msg) = @_;

    my $payload = $req->{request};
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};
    return {ok => 0, error => "missing request type"} unless defined $type;

    my $handler = "request_handler_$type";
    return $self->$handler($payload) if $self->can($handler);

    return {ok => 0, error => "unknown request '$type'"};
}

sub request_handler_terminate {
    my $self = shift;
    $self->perform_hard_stop;
    return {ok => 1};
}

# Optional consumer overrides. Each has a default so the role can call
# them unconditionally.

# Whether this service should register as a subreaper in run_on_start.
# The two in-tree services (Test2::Harness2 and
# Test2::Harness2::RunService) override to 1; roles consumed by
# services that don't need subreaper semantics can leave it off.
sub become_sub_reaper { 0 }

# Extra fields merged into the service_started event. Default: none.
sub service_started_fields { () }

# Run after pgroup/subreaper/service_started. Default: no-op.
sub service_on_start { }

# Run before hard_stop_pids is consulted. Default: no-op.
sub service_pre_hard_stop { }

# Called once per pid reaped inside the escalator loop. Default: no-op.
sub service_on_reaped { }

# Run after the escalator finishes. Default: no-op.
sub service_post_hard_stop { }

# Startup. Handles the three steps every service performs identically:
# own the process group, optionally become a subreaper, and emit a
# service_started event. Consumer hooks fill in the extra work.
sub run_on_start {
    my $self = shift;

    # Own our pgroup so signals from managed children (tests, resource
    # services) can't reach us via pgroup delivery. Signals go out by
    # pid, never by pgroup, so pgroup isolation is enough.
    my $pgroup_set = 0;
    if (POSIX::setpgid(0, 0)) {
        $self->set_own_pgroup(1);
        $pgroup_set = 1;
    }
    else {
        warn "setpgid(0,0) failed in run_on_start: $!";
    }

    # Ask the kernel to treat us as a subreaper when the consumer
    # requests it. Reparented descendants (double-forks, setsid +
    # parent-exit patterns) land on us instead of init(1), which lets
    # perform_hard_stop reach them at shutdown and lets IPC::Manager's
    # per-tick waitpid drive run_on_pid for them. Skipped silently on
    # platforms / builds without subreaper support.
    my $subreaper_set = 0;
    if (HAS_CHILD_SUBREAPER && $self->become_sub_reaper) {
        if (Test2::Harness2::ChildSubReaper::set_child_subreaper(1)) {
            $subreaper_set = 1;
        }
        else {
            warn "set_child_subreaper failed in run_on_start: $!";
        }
    }

    $self->emit_service_event(
        kind          => 'service_started',
        pid           => $$,
        pgid          => getpgrp(),
        name          => $self->name,
        workdir       => $self->workdir,
        pgroup_set    => $pgroup_set    ? 1 : 0,
        subreaper_set => $subreaper_set ? 1 : 0,
        $self->service_started_fields,
    );

    $self->service_on_start;

    return;
}

# Shared hard-stop escalator. The consumer provides the initial pid
# map via hard_stop_pids and optionally supplies hooks for pre-stop
# flagging, mid-loop reap bookkeeping, and post-stop state clearing.
#
# The escalator is a single loop that iterates until every tracked pid
# is either reaped or IGNORE'd (still alive after KILL + grace). Each
# tick:
#
#   1. Re-enumerate subreaper children so newly-reparented descendants
#      join the set with their own grace window.
#   2. Send the first signal (TERM on Unix, INT on Windows) to any pid
#      that has not been signalled yet.
#   3. Send KILL to any pid whose TERM grace window has elapsed.
#   4. waitpid(-1, WNOHANG) until nothing more is ready; deletion from
#      %pids happens here, and the consumer's service_on_reaped hook
#      fires once per reap.
#   5. tinysleep briefly if nothing was signalled or reaped so the
#      consumer is not busy-waiting.
sub perform_hard_stop {
    my $self = shift;

    $self->set_state('terminating');

    # Let the consumer flip its own state before we enumerate pids
    # (e.g. Harness2 drains its queue so a racing run_on_all tick does
    # not try to schedule mid-shutdown).
    $self->service_pre_hard_stop;

    my $grace = $self->kill_timeout;

    my %pids = $self->hard_stop_pids;

    # First-pass subreaper enumeration picks up anything already
    # reparented to us at entry.
    if (HAS_CHILD_SUBREAPER) {
        $pids{$_} //= {} for list_direct_children($$);
    }

    # Drop anything that IPC::Manager's per-tick waitpid already reaped
    # before we got here.
    delete $pids{$_} for grep { !kill(0, $_) } keys %pids;

    my $first_sig = IS_WIN32 ? 'INT' : 'TERM';

    while (1) {
        # Subreaper re-enumeration: a new layer may have been orphaned
        # onto us since the last iteration. Newcomers arrive with an
        # empty signal map so they get the full grace window, not the
        # state of the layer above them.
        if (HAS_CHILD_SUBREAPER) {
            $pids{$_} //= {} for list_direct_children($$);
        }

        my (@fresh, @to_kill, $unignored);
        for my $pid (keys %pids) {
            my $state = $pids{$pid};
            next if $state->{IGNORE};

            $unignored++;

            if (my $f_ts = $state->{$first_sig}) {
                if (my $k_ts = $state->{KILL}) {
                    $state->{IGNORE} = 1
                        if (time - $k_ts) >= $grace;
                    $unignored-- if $state->{IGNORE};
                }
                elsif ((time - $f_ts) >= $grace) {
                    push @to_kill => $pid;
                }
            }
            else {
                push @fresh => $pid;
            }
        }

        last unless $unignored;

        if (@fresh) {
            kill($first_sig => @fresh);
            my $now = time;
            $pids{$_}{$first_sig} = $now for @fresh;
        }
        if (@to_kill) {
            kill(KILL => @to_kill);
            my $now = time;
            $pids{$_}{KILL} = $now for @to_kill;
        }

        my $reaped = 0;
        while (my $pid = waitpid(-1, WNOHANG)) {
            last if $pid < 1;
            delete $pids{$pid};
            $self->service_on_reaped($pid);
            $reaped = 1;
        }

        tinysleep(0.05) unless $reaped || @fresh || @to_kill;
    }

    $self->service_post_hard_stop;

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Shared skeleton for Test2::Harness2
long-lived services (harness, per-run supervisor, future preloader,
etc.).

=head1 DESCRIPTION

Every Test2::Harness2 service is an L<IPC::Manager::Role::Service> that:

=over 4

=item * Owns its own process group and optionally acts as a subreaper
for its descendants.

=item * Emits a C<service_started> event at startup and
C<service_stopped> at clean exit.

=item * Dispatches IPC requests to C<request_handler_*> methods.

=item * Accepts a C<terminate> request that triggers a TERM-then-KILL
escalator across every pid it owns, falling back to KILL on pids that
survive a grace window and eventually IGNORE'ing anything that is
unreachable by signal.

=back

This role carries that common scaffolding so each concrete service
only supplies the domain-specific bits: what pids to track at
shutdown, what extra fields its C<service_started> event should carry,
and what its own startup steps are.

=head1 SYNOPSIS

    package My::Harness::Service;
    use Object::HashBase qw{
        <workdir <name kill_timeout state own_pgroup watch_pids ...
    };

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    # Required:
    sub emit_service_event { ... }     # emit an event to the host's log
    sub hard_stop_pids     { ... }     # return pid => {} map

    # kill_timeout / state / own_pgroup / watch_pids accessors come
    # from the Object::HashBase declarations above (sigil-free slot
    # names generate both a getter and a set_<name> setter).

    # Optional overrides (defaults provided):
    sub become_sub_reaper     { 1 }
    sub service_started_fields { (run_id => $_[0]->run_id) }
    sub service_on_start       { $_[0]->start_resource_services(...) }
    sub service_pre_hard_stop  { $_[0]->{queue} = [] }
    sub service_on_reaped      { delete $_[0]->{test_jobs}{$_[1]} }
    sub service_post_hard_stop { ... }

=head1 REQUIRED METHODS

=over 4

=item $path = $service->workdir

Working directory. Surfaced in the C<service_started> event.

=item $name = $service->name

Short human-readable name (e.g. C<"harness">, C<"run-$run_id">). Used
in the C<service_started> event and in the default service-log paths.

=item $service->emit_service_event(%fields)

Emit a structured event. Called by the role for C<service_started>;
consumers may call it for their own events. Implementations differ
(the harness writes through an event emitter; the run service writes
JSONL directly), which is why the role has no default.

=item %pids = $service->hard_stop_pids

Return a hash of C<< pid => {} >> for every pid the service owns when
C<perform_hard_stop> starts. The role then layers subreaper children
on top and drives the TERM/KILL escalator; the consumer does not need
to filter for already-dead pids.

=item $secs = $service->kill_timeout

Grace window (seconds) between the first signal (TERM/INT) and KILL
during C<perform_hard_stop>.

=item $pids = $service->watch_pids

Arrayref of pids IPC::Manager's per-tick C<waitpid> should monitor.
This is the L<IPC::Manager::Role::Service> contract accessor; the
role surfaces it here so every service exposes its pid set through
the same accessor.

=item $service->set_state($new)

Write C<$new> to the service's state slot. The role calls
C<< ->set_state('terminating') >> at the start of
C<perform_hard_stop>.

=item $service->set_own_pgroup($bool)

Write a boolean flag recording whether C<setpgid(0, 0)> succeeded
during C<run_on_start>. The role sets it from C<run_on_start>; the
consumer reads it wherever it wants to know if the process is in its
own pgroup.

=back

=head1 OPTIONAL HOOKS

Each has a default implementation (empty or C<0>), so the role can
call them unconditionally.

=over 4

=item $bool = $service->become_sub_reaper

Default C<0>. Override to C<1> if the service should call
C<set_child_subreaper(1)> at startup. Both in-tree services do.

=item %fields = $service->service_started_fields

Extra key/value pairs to merge into the C<service_started> event. The
role already supplies C<kind>, C<pid>, C<pgid>, C<name>, and
C<workdir>.

=item $service->service_on_start

Called from C<run_on_start> after the pgroup / subreaper / event
steps. Use this for consumer-specific startup work (e.g. writing an
initial snapshot, starting resource services).

=item $service->service_pre_hard_stop

Called before the escalator enumerates pids. Use this to flip
consumer-specific state (e.g. draining a scheduler queue) so nothing
races the shutdown.

=item $service->service_on_reaped($pid)

Called once per pid reaped inside the escalator loop. Use this to
clean up consumer-specific tracking hashes mid-shutdown.

=item $service->service_post_hard_stop

Called after the escalator finishes. Use this to release resources,
clear tracking hashes, etc.

=back

=head1 PROVIDED METHODS

=over 4

=item $self->run_on_start

Does C<setpgid(0, 0)>, optionally becomes a subreaper via
L<Test2::Harness2::ChildSubReaper> (when C<become_sub_reaper> returns
true), emits C<service_started>, and calls C<service_on_start>.
The emitted event carries C<pgroup_set> and C<subreaper_set> boolean
fields reflecting whether those setup steps actually succeeded; a
consumer watching its own log (or a downstream aggregator) can
detect a degraded startup without re-deriving it.

=item $response = $self->handle_request($req, $msg)

Unwraps the request envelope and dispatches to
C<request_handler_$type> on the consumer. Returns a C<< {ok => 0,
error => ...} >> hashref for missing or unknown request types.

=item $response = $self->request_handler_terminate

Default handler that calls C<perform_hard_stop> and returns C<< {ok
=> 1} >>. Consumers that need a different shape may override.

=item $self->perform_hard_stop

TERM-then-KILL escalator. Sets the consumer's C<state> slot to
C<terminating>, calls the optional pre/on-reaped/post hooks, and
drives the loop documented inline in the source.

=item orig_io, pid, set_pid

L<IPC::Manager::Role::Service> contract accessors with hash-backed
defaults. C<orig_io> returns an empty hashref, C<pid> defaults to
C<$$> on first read and is writable via C<set_pid>.
C<watch_pids> is required of the consumer (see L</REQUIRED METHODS>
above).

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
