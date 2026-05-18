package App::Yath2::Renderer2::Loop;
use strict;
use warnings;

our $VERSION = '2.000013';

# FileMonitor API (discovered from lib/Test2/Harness2/Util/FileMonitor.pm):
#
#   $monitor->changed           — non-blocking; returns truthy if file has
#                                 changed since the last changed() or
#                                 await_change() call. First call always
#                                 returns truthy (the "start" baseline).
#
#   $monitor->peek_changed      — non-consuming variant; does NOT ack the
#                                 pending change.
#
#   $monitor->await_change($timeout) — blocking wait. Returns truthy (delegate
#                                 or 1) when a change is observed, 0 on
#                                 timeout. Uses inotify when available; falls
#                                 back to a tinysleep poll loop that reacts
#                                 promptly to SIGCHLD / SIGTERM.
#
# _wait_for_change below uses await_change with a short timeout so the outer
# loop can re-evaluate shutdown conditions regularly. The timeout is bounded
# by $poll so the loop stays responsive even without inotify.

use File::Spec ();

use Test2::Harness2::Util::FileMonitor;
use Test2::Harness2::Util qw/tinysleep/;

# run($renderer) — drive the renderer loop from a Log abstraction.
#
# Procedural sub (not a class method). Fires handle_<kind>_opened exactly once
# per producer on first sighting and handle_<kind>_sealed exactly once on the
# transition to the sealed state. Sealed logs do one pass and exit; live logs
# loop until a shutdown condition fires, then do one drain pass before calling
# finish.
sub run {
    my ($r) = @_;
    $r->start;

    my $log      = $r->log;
    my $is_live  = $log->is_live;
    my $settings = $r->settings               // {};
    my $poll     = $settings->{poll_interval} // 0.05;

    my ($live_path, $live_monitor);
    if ($is_live) {
        $live_path    = File::Spec->catfile($log->path, 'LIVE');
        $live_monitor = Test2::Harness2::Util::FileMonitor->new(
            file          => $live_path,
            poll_interval => $poll,
        );
    }

    my $draining = 0;

    while (1) {
        _scan_once($r);

        last unless $is_live;
        last if $draining;

        # Three shutdown checks — all evaluated, any positive triggers drain.
        my $shutdown = 0;
        $shutdown ||= defined($live_path) && !-e $live_path;
        $shutdown ||= _check_ipc_signal($r);
        $shutdown ||= !_pid_alive($r->parent_pid);
        $shutdown ||= !_pid_alive($r->command_pid);

        if ($shutdown) {
            $draining = 1;
            next;
        }

        _wait_for_change($r, $live_monitor, $poll);
    }

    $r->finish;
    return;
}

# _scan_once($r) — walk runs, jobs, services, collectors once.
# For each producer, fire _process_producer which manages the two-hook
# state machine (opened_fired / sealed_fired).
#
# Nesting order for runs: fire handle_run_opened first, then process all
# child jobs and services, then fire handle_run_sealed. This gives the
# natural top-down / inside-out ordering:
#   run_opened → job_opened → job_sealed → run_sealed.
sub _scan_once {
    my ($r) = @_;
    my $log = $r->log;

    for my $run_p ($log->run_producers->all) {
        my $run_key = 'run/' . $run_p->id;
        my $run_st  = $r->_state->{$run_key} ||= {};

        # Fire the opened hook before descending into children.
        unless ($run_st->{opened_fired}) {
            $r->handle_run_opened($run_p);
            $run_st->{opened_fired} = 1;
        }

        for my $job_p ($log->job_producers($run_p->id)->all) {
            _process_producer(
                $r, $job_p,
                opened_hook => 'handle_job_opened',
                sealed_hook => 'handle_job_sealed',
                state_key   => 'job/' . $run_p->id . '/' . $job_p->id . '/' . ($job_p->try // 0),
            );
        }

        for my $svc_p ($log->service_producers($run_p->id)->all) {
            _process_producer(
                $r, $svc_p,
                opened_hook => 'handle_service_opened',
                sealed_hook => 'handle_service_sealed',
                state_key   => 'service/' . ($run_p->id // '_') . '/' . $svc_p->id,
            );
        }

        # Fire the sealed hook after all children have been processed.
        if ($run_p->state eq 'sealed' && !$run_st->{sealed_fired}) {
            $r->handle_run_sealed($run_p);
            $run_st->{sealed_fired} = 1;
        }
    }

    for my $col_p ($log->collector_producers->all) {
        _process_producer(
            $r, $col_p,
            opened_hook => 'handle_collector_opened',
            sealed_hook => 'handle_collector_sealed',
            state_key   => 'collector/' . $col_p->id,
        );
    }

    return;
}

# _process_producer($r, $producer, %opts) — two-hook state machine.
#
# Fires the opened hook exactly once on first sighting (regardless of state)
# and the sealed hook exactly once when the producer's state reaches 'sealed'.
# State is stored on the renderer's _state hashref under state_key.
sub _process_producer {
    my ($r, $producer, %opts) = @_;
    my $st = $r->_state->{$opts{state_key}} ||= {};

    unless ($st->{opened_fired}) {
        my $hook = $opts{opened_hook};
        $r->$hook($producer);
        $st->{opened_fired} = 1;
    }

    if ($producer->state eq 'sealed' && !$st->{sealed_fired}) {
        my $hook = $opts{sealed_hook};
        $r->$hook($producer);
        $st->{sealed_fired} = 1;
    }

    return;
}

# _wait_for_change($r, $live_monitor, $poll) — block until any change source
# fires or a short timeout elapses.
#
# Uses FileMonitor->await_change with a capped timeout so the outer loop
# re-evaluates shutdown conditions at least every $poll seconds. Also polls
# artifact monitors registered by the renderer (for verbose artifact tailing).
sub _wait_for_change {
    my ($r, $live_monitor, $poll) = @_;

    # Check artifact monitors first (non-blocking). For each that reports a
    # change, dispatch on_artifact_change so the subclass knows which monitor
    # fired before we return to the scan loop.
    my $any_changed = 0;
    my %entries     = $r->_artifact_monitor_entries;
    while (my ($key, $am) = each %entries) {
        if ($am->changed) {
            $r->on_artifact_change($key, $am);
            $any_changed = 1;
        }
    }
    return if $any_changed;

    # Block on the LIVE monitor with a short timeout so shutdown conditions
    # (LIVE removal, dead PID) are re-checked promptly. await_change wakes
    # immediately when inotify events are queued; the timeout caps the worst-
    # case latency on non-inotify filesystems.
    $live_monitor->await_change($poll) if $live_monitor;

    return;
}

# _pid_alive($pid) — return 1 when $pid is running, 0 otherwise.
# A PID of undef or <= 0 is treated as "alive" (not our concern).
sub _pid_alive {
    my $pid = shift;
    return 1 unless defined $pid && $pid > 0;
    return kill(0, $pid) ? 1 : 0;
}

# _check_ipc_signal($r) — poll the IPC bus for a renderer_stop message.
#
# Short-circuits to 0 when ipc_disabled is set or no client is connected.
# Delegates to Base->ipc_stop_signaled, which is sticky once true.
sub _check_ipc_signal {
    my ($r) = @_;
    return 0 if $r->ipc_disabled;
    return 0 unless $r->_has_ipc;
    return $r->ipc_stop_signaled;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::Loop - Render loop with two-hook handler model.

=head1 SYNOPSIS

    use App::Yath2::Renderer2::Loop;
    use My::Renderer;

    my $r = My::Renderer->new(log => $log, parent_pid => $$, ...);
    App::Yath2::Renderer2::Loop::run($r);

=head1 DESCRIPTION

Procedural render loop that drives an C<App::Yath2::Renderer2::Base>
subclass. The loop:

=over 4

=item 1.

Calls C<< $renderer->start >>.

=item 2.

Scans the log for runs, jobs (nested inside each run), services (nested
inside each run), and collectors. For each producer it fires
C<handle_<kind>_opened> exactly once on first sighting and
C<handle_<kind>_sealed> exactly once when the producer's state reaches
C<'sealed'>. The fired state is tracked on the renderer's C<_state>
hashref using per-producer keys.

=item 3.

For sealed logs (C<< $log->is_live >> false) the loop does one pass and
exits. For live logs the loop waits for the LIVE sentinel file to change
(via L<Test2::Harness2::Util::FileMonitor/await_change>) before
repeating the scan.

=item 4.

Three shutdown conditions trigger a drain pass (one final scan) after
which the loop exits: the C<LIVE> file is removed, an IPC C<renderer_stop>
message is received, or either of the tracked PIDs (parent and command)
is no longer alive.

=item 5.

Calls C<< $renderer->finish >> after the loop exits.

=back

=head1 FUNCTIONS

=over 4

=item App::Yath2::Renderer2::Loop::run($renderer)

Entry point. Drives the render loop for C<$renderer>. Does not return
until the loop exits. Never call this as a method; it is a plain
procedural sub.

=back

=head1 INTERNAL FUNCTIONS

The following are implementation details. They are documented here for
maintainability but are not part of the public API.

=over 4

=item _scan_once($r)

Walk all producers once and fire the two-hook state machine for each.

=item _process_producer($r, $producer, %opts)

Two-hook state machine. Fires C<opened_hook> once on first sighting and
C<sealed_hook> once when state reaches C<'sealed'>.

=item _wait_for_change($r, $live_monitor, $poll)

Block until any monitored source (LIVE file or registered artifact monitors)
changes, or the poll interval elapses. For each artifact monitor that reports
a change, calls C<< $r->on_artifact_change($key, $monitor) >> before returning
so the renderer subclass knows which monitor fired.

=item _pid_alive($pid)

Return 1 if C<$pid> is still running (via C<kill 0>), 0 otherwise.
C<undef> or non-positive PIDs return 1 (not our concern).

=item _check_ipc_signal($r)

Returns 0 immediately when C<< $r->ipc_disabled >> is true or no IPC client
is connected (C<< $r->_has_ipc >> is false). Otherwise delegates to
C<< $r->ipc_stop_signaled >>, which polls the bus non-blocking for a
C<renderer_stop> message (sticky once seen).

=back

=head1 FILEMONITOR API

The loop uses L<Test2::Harness2::Util::FileMonitor> with two methods:

=over 4

=item C<< $monitor->changed >>

Non-blocking. Returns truthy when the monitored file has changed since the
previous call (or is the first call). Used to poll artifact monitors.

=item C<< $monitor->await_change($timeout) >>

Blocking wait. Returns truthy on change, C<0> on timeout. Uses inotify when
available; falls back to a C<tinysleep> poll so signals are not swallowed.
Used to block on the LIVE sentinel file.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
