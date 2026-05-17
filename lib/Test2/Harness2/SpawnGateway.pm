package Test2::Harness2::SpawnGateway;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/time/;
use POSIX qw/WNOHANG/;

use Object::HashBase qw{
    +pending_script_spawns
    +_script_spawn_counter
    +_script_spawn_exits
    +harness
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

sub init {
    my $self = shift;
    $self->{+PENDING_SCRIPT_SPAWNS}  //= {};
    $self->{+_SCRIPT_SPAWN_COUNTER}  //= 0;
    $self->{+_SCRIPT_SPAWN_EXITS}    //= {};
}

# Handle a 'spawn_script' request from a CLI client. Resolves the
# requested stage name to a live PreloadService, asserts that the IPC
# transport can carry file descriptors (ConnectionUnix only), and
# forwards the payload to that service's bus name so the preload fork
# can exec the script with the preloaded environment intact.
#
# Returns a hashref: { ok => 1, mode => 'preload', spawn_id => N } on
# success, { ok => 0, error => "..." } on any failure (missing stage,
# wrong transport, dispatch failure).
sub handle_request {
    my ($self, $payload, $msg) = @_;

    for my $f (qw/script_abs env cwd sock_path notify_to/) {
        return { ok => 0, error => "missing '$f' in spawn_script payload" }
            unless defined $payload->{$f};
    }

    my $stage = $payload->{stage};
    return { ok => 0, error => "'stage' is required" }
        unless defined $stage && length $stage;

    my $ok  = eval { $self->assert_fdpass_transport; 1 };
    my $err = $@;
    return { ok => 0, error => $err } unless $ok;

    my $h = $self->harness
        or return { ok => 0, error => "harness gone away" };

    my $preload_info = $h->_find_eligible_preload_service($stage);
    return { ok => 0, error => "no eligible preload stage named '$stage'" }
        unless $preload_info;

    my $spawn_id = ++$self->{+_SCRIPT_SPAWN_COUNTER};
    require Test2::Harness2;
    my $bus_name = Test2::Harness2::_preload_peer_name($preload_info->{resource});

    $self->{+PENDING_SCRIPT_SPAWNS}->{$spawn_id} = {
        notify_to   => $payload->{notify_to},
        stage       => $stage,
        preload_pid => $preload_info->{pid},
        sent_at     => time,
    };

    my $client  = $h->client;
    my $sent_ok = eval {
        $client->send_message($bus_name, {
            kind       => 'spawn_script',
            script_abs => $payload->{script_abs},
            argv       => $payload->{argv} // [],
            env        => $payload->{env},
            cwd        => $payload->{cwd},
            sock_path  => $payload->{sock_path},
            spawn_id   => $spawn_id,
            notify_to  => $h->name,
        });
        1;
    };
    my $send_err = $@;

    unless ($sent_ok) {
        delete $self->{+PENDING_SCRIPT_SPAWNS}->{$spawn_id};
        return { ok => 0, error => "dispatch failed: $send_err" };
    }

    return { ok => 1, mode => 'preload', spawn_id => $spawn_id };
}

# Script-spawn grandchild exit. IPC::Manager's reap_children
# (waitpid -1) reaps the grandchild before poll() can see it, so we
# handle the notification here.
#
# Two sub-cases:
#   (a) script_spawned already arrived -> child_pid is set; send
#       script_exited immediately.
#   (b) script_spawned races the reap -> child_pid not yet set; stash
#       the exit in _SCRIPT_SPAWN_EXITS for handle_spawned to drain.
#       Only stash when *some* pending entry still lacks a child_pid --
#       otherwise this pid belongs to something else (resource service,
#       reparented descendant) and stashing would leak unboundedly.
#
# Returns true when this pid maps to a known script-spawn entry
# definitively. Returns false (the "race case") so the caller still
# asks the resource-service handler.
sub handle_pid_exit {
    my ($self, $pid, $exit) = @_;

    my $table = $self->{+PENDING_SCRIPT_SPAWNS} // {};
    my $expecting_unmatched = 0;
    for my $sid (keys %$table) {
        my $entry = $table->{$sid};
        if (defined($entry->{child_pid}) && $entry->{child_pid} == $pid) {
            $self->dispatch_exited($sid, $entry, $exit);
            delete $table->{$sid};
            return 1;
        }
        $expecting_unmatched = 1 unless defined $entry->{child_pid};
    }

    # Race case: stash speculatively but report "not handled" so the
    # caller still asks the resource-service handler.
    $self->{+_SCRIPT_SPAWN_EXITS}->{$pid} = $exit if $expecting_unmatched;
    return 0;
}

# Record the grandchild pid that the preload service sent back after
# fork()ing the script. The spawn_id ties this notification back to the
# PENDING_SCRIPT_SPAWNS entry created by handle_request.
sub handle_spawned {
    my ($self, $content) = @_;
    my $sid = $content->{spawn_id} or return;
    my $pid = $content->{pid}      or return;
    my $pending = $self->{+PENDING_SCRIPT_SPAWNS}->{$sid}
        or return;
    $pending->{child_pid} = $pid;

    # Race case: the grandchild may have exited and been reaped by
    # run_on_pid before script_spawned arrived. If so the raw exit
    # value is sitting in _SCRIPT_SPAWN_EXITS keyed on pid; drain
    # it and dispatch script_exited immediately.
    my $exits = $self->{+_SCRIPT_SPAWN_EXITS} // {};
    if (exists $exits->{$pid}) {
        my $status = delete $exits->{$pid};
        my $sent   = $self->dispatch_exited($sid, $pending, $status);
        delete $self->{+PENDING_SCRIPT_SPAWNS}->{$sid} if $sent;
    }
    return;
}

# Build and send a script_exited notification. Returns true on success,
# false on send failure (caller may keep the pending entry alive to
# retry or to avoid leaving the CLI blocked forever on a never-arriving
# notification).
sub dispatch_exited {
    my ($self, $sid, $pending, $status) = @_;
    my $exit_val = ($status >> 8) & 0xFF;
    my $sig      = $status & 0x7F;
    my $h        = $self->harness or return 0;
    my $client   = $h->client;
    my $ok = eval {
        $client->send_message($pending->{notify_to}, {
            kind       => 'script_exited',
            spawn_id   => $sid,
            exit       => $exit_val,
            signal     => $sig,
            raw_status => $status,
        });
        1;
    };
    my $err = $@;
    warn "yath spawn: script_exited dispatch failed: $err" unless $ok;
    return $ok ? 1 : 0;
}

# Defensive backup: in normal operation IPC::Manager's reap_children
# (waitpid -1) reaps the grandchild and run_on_pid dispatches via
# dispatch_exited. poll() handles the case where that path doesn't
# fire (test isolation, IPC::Manager version differences).
sub poll {
    my $self = shift;

    my $table = $self->{+PENDING_SCRIPT_SPAWNS} // {};
    for my $sid (keys %$table) {
        my $entry = $table->{$sid};
        my $cpid  = $entry->{child_pid};
        next unless defined $cpid;

        my $reaped = waitpid($cpid, WNOHANG);
        next if $reaped == 0;     # still running
        next if $reaped < 0;     # already reaped elsewhere

        my $sent = $self->dispatch_exited($sid, $entry, $?);
        delete $table->{$sid} if $sent;
    }

    return;
}

# Throws if the IPC transport in use can't carry SCM_RIGHTS. yath
# spawn is the only caller; placing the check here lets us fail fast
# before any client-side socket setup. The check looks at the
# ipcm_info advertised to clients, which is the same string the
# harness wrote at startup.
sub assert_fdpass_transport {
    my $self = shift;
    my $h    = $self->harness;
    my $info = ($h && $h->ipcm_info) // '';
    return 1 if $info =~ m{IPC::Manager::Client::ConnectionUnix};
    die "yath spawn requires the ConnectionUnix IPC transport "
      . "(current ipcm_info: $info)\n";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::SpawnGateway - C<yath spawn> SCM_RIGHTS pathway for the harness.

=head1 DESCRIPTION

The spawn gateway owns the state and handlers for the C<yath spawn>
pathway: it accepts a C<spawn_script> request from a CLI client,
asserts the IPC transport can carry SCM_RIGHTS, picks a live
L<Test2::Harness2::PreloadService> that matches the requested stage,
forwards the script's exec payload to that service's bus name, and
finalizes by sending a C<script_exited> notification back to the CLI
when the grandchild eventually exits.

The harness constructs one SpawnGateway during its own C<init> and
holds a strong reference to it. The gateway holds a weakened backref
to the harness via L<Test2::Harness2::Role::Subsystem> so it can
reach the harness's IPC client, the C<ipcm_info> string, the
preload-eligibility lookup, and the bus-name derivation helper.

The harness's C<run_on_pid> short-circuits when L</handle_pid_exit>
definitively matches a known script spawn; the "race case" returns
false so the resource-service handler still gets a chance to claim
the pid.

The harness's C<run_on_interval> calls L</poll> each tick as a
defensive backup for the rare case where C<run_on_pid> never fires
for the grandchild (test isolation, IPC::Manager version differences).

=head1 METHODS

=over 4

=item $resp = $sg->handle_request($payload, $msg)

Handle a C<spawn_script> request from a CLI client. Returns
C<< { ok => 1, mode => 'preload', spawn_id => N } >> on success or
C<< { ok => 0, error => "..." } >> on any failure (missing field,
wrong transport, no eligible stage, dispatch failure).

=item $bool = $sg->handle_pid_exit($pid, $exit)

Called from the harness's C<run_on_pid>. Returns true when C<$pid>
definitively maps to a known script-spawn entry (the exit was
dispatched); returns false in the "race case" where the exit was
stashed speculatively so the harness can still ask its
resource-service handler.

=item $sg->handle_spawned($msg)

Records the grandchild pid the preload service reports back after
forking the script. If C<handle_pid_exit> already stashed a raw exit
for that pid (race case), drains it and dispatches the
C<script_exited> notification immediately.

=item $ok = $sg->dispatch_exited($sid, $pending, $status)

Build and send a C<script_exited> notification to the CLI's notify
peer. Returns true on send success, false on send failure (the
pending entry may be kept so a later poll can retry).

=item $sg->poll

Defensive backup reaper for C<yath spawn> grandchildren. Walks the
pending table and C<waitpid(..., WNOHANG)>s any entry with a known
child pid; on a successful reap, dispatches the C<script_exited>
notification.

=item $sg->assert_fdpass_transport

Dies unless the configured IPC transport is
C<IPC::Manager::Client::ConnectionUnix> (the only transport that can
carry SCM_RIGHTS, which C<yath spawn> needs).

=item $h = $sg->harness

Returns the harness reference, or C<undef> when no harness is bound
or the harness has gone away. Inherited from
L<Test2::Harness2::Role::Subsystem>.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::PreloadService>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
