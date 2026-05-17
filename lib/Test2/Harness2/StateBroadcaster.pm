package Test2::Harness2::StateBroadcaster;
use strict;
use warnings;

our $VERSION = '2.000013';

use Object::HashBase qw{
    +subscribers
    +subscriber_retry
    +harness
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

# Per-peer pending-retry queue cap. A subscriber that never drains will
# otherwise balloon harness memory. When the cap is hit the oldest
# payloads are dropped (FIFO) and the broadcaster warns once.
use constant SUBSCRIBER_RETRY_CAP => 1024;

sub init {
    my $self = shift;
    $self->{+SUBSCRIBERS}      //= {};
    $self->{+SUBSCRIBER_RETRY} //= {};
}

# Register / extend a subscriber's interest. Validates run_ids against
# the harness's live queue and COMPLETED_RUNS map; an unknown run id is
# rejected. The first subscription to a run also sends an initial state
# snapshot so the subscriber does not need to separately request it.
#
# Registry shape:
#   { $peer_name => {
#         global => $bool,      # (future) harness-level state
#         runs   => { $id=>1 }, # run ids the subscriber watches
#         state  => $bool,      # want state change messages
#     } }
sub subscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "subscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    my $h = $self->harness
        or return {ok => 0, error => "harness gone away"};

    my $global = $payload->{global} ? 1 : 0;
    my $state  = $payload->{state}  ? 1 : 0;

    my @run_ids;
    push @run_ids => $payload->{run}     if defined $payload->{run};
    push @run_ids => @{$payload->{runs}} if ref($payload->{runs}) eq 'ARRAY';

    # Validate every run_id up front. The harness knows about runs in
    # the live queue and in COMPLETED_RUNS (terminal snapshots).
    for my $rid (@run_ids) {
        next if grep { $_->run_id eq $rid } @{$h->{Test2::Harness2::QUEUE()} // []};
        next if $h->{Test2::Harness2::COMPLETED_RUNS()}->{$rid};
        return {ok => 0, error => "unknown run '$rid'"};
    }

    my $entry = $self->{+SUBSCRIBERS}->{$peer} //= {
        global => 0,
        runs   => {},
        state  => 0,
    };
    $entry->{global} ||= $global;
    $entry->{state}  ||= $state;
    $entry->{runs}->{$_} = 1 for @run_ids;

    # Send an initial state snapshot for each freshly-added run so the
    # subscriber does not need to separately request it.
    if ($state) {
        for my $rid (@run_ids) {
            $self->send_snapshot($peer, run_id => $rid);
        }
    }

    return {ok => 1};
}

# Clean unsubscribe: drop the peer from the registry and discard any
# pending retries. Idempotent on unknown peers.
sub unsubscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "unsubscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    delete $self->{+SUBSCRIBERS}->{$peer};
    delete $self->{+SUBSCRIBER_RETRY}->{$peer};

    return {ok => 1};
}

# Fan-out to subscribers interested in $run_id. Full snapshot each
# time; consumers diff on their side.
sub notify_state {
    my ($self, $run_id, $run_data) = @_;
    return unless defined $run_id;

    for my $peer (keys %{$self->{+SUBSCRIBERS}}) {
        my $entry = $self->{+SUBSCRIBERS}->{$peer};
        next unless $entry->{state};
        next unless $entry->{runs}->{$run_id};

        $self->send(
            $peer => {
                type   => 'state',
                item   => 'run',
                run_id => $run_id,
                state  => $run_data,
            },
        );
    }
    return;
}

# Send a one-off state snapshot for $run_id to $peer. Uses the live
# Run::State if the run is in the queue, the COMPLETED_RUNS terminal
# snapshot otherwise. Unknown run ids are silent no-ops.
sub send_snapshot {
    my ($self, $peer, %params) = @_;
    my $run_id = $params{run_id} or return;

    my $h = $self->harness or return;

    my $run_data;
    if (grep { $_->run_id eq $run_id } @{$h->{Test2::Harness2::QUEUE()} // []}) {
        my $rstate = $h->{Test2::Harness2::RUN_STATES()}->{$run_id};
        $run_data = $rstate ? $rstate->TO_JSON : {run_id => $run_id};
    }
    elsif (my $info = $h->{Test2::Harness2::COMPLETED_RUNS()}->{$run_id}) {
        # Completed snapshot is not a Run-shaped TO_JSON; wrap it so
        # consumers still see the same {type,item,run_id,state} shape.
        $run_data = {
            run_id  => $run_id,
            state   => 'complete',
            results => $info->{results} // {},
            done    => $info->{done}    // [],
            pass    => $info->{pass},
        };
    }
    else {
        return;
    }

    $self->send(
        $peer => {
            type   => 'state',
            item   => 'run',
            run_id => $run_id,
            state  => $run_data,
        },
    );
}

# Deliver one message to a subscriber. Uses the harness's own client
# to piggy-back on IPC::Manager's internal peer cache instead of
# constructing a new Handle per-peer (Handles are only needed when the
# sender is doing a sync_request and needs to wait for a response; a
# plain send_message() goes through the client directly and accepts
# any named peer on the bus, including clients that are not themselves
# services).
#
# On a send failure we ask the bus whether the peer is still
# registered. If peer_exists() says yes, the failure is transient
# (bus congestion, a racing suspend, etc.) and we queue a retry for
# the next tick. If peer_exists() says no, the peer is gone for good;
# skip the retry and unsubscribe now so we stop sending them anything
# else.
sub send {
    my ($self, $peer, $payload) = @_;

    my $h = $self->harness or return;
    my $client = $h->client;

    my $ok  = eval { $client->send_message($peer, $payload); 1 };
    my $err = $@;

    return if $ok;

    my $peer_alive = eval { $client->peer_exists($peer) };
    unless ($peer_alive) {
        warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
        delete $self->{+SUBSCRIBERS}->{$peer};
        delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        return;
    }

    my $retry = $self->{+SUBSCRIBER_RETRY}->{$peer} //= {};
    $retry->{pending} //= [];
    push @{$retry->{pending}} => $payload;

    # Cap per-peer retry queue. A subscriber that never drains will
    # otherwise balloon harness memory. When the cap is hit, drop the
    # oldest payloads (FIFO) and warn once -- the consumer is broken
    # in some way and there is no good way to recover the lost
    # messages, but the harness must stay healthy.
    my $cap = SUBSCRIBER_RETRY_CAP;
    if (@{$retry->{pending}} > $cap) {
        my $excess = @{$retry->{pending}} - $cap;
        splice @{$retry->{pending}}, 0, $excess;
        unless ($retry->{capped_warned}++) {
            warn "Test2::Harness2: subscriber '$peer' retry queue exceeded " . "$cap; dropping oldest payloads.\n";
        }
    }
    return;
}

# Called once per service tick to drain retries. Per-payload the same
# peer_alive gate applies: a send failure is retried while the peer is
# still on the bus, and dropped (with the peer unsubscribed) once
# peer_exists() reports it gone.
sub drain_retries {
    my $self = shift;

    my $retries = $self->{+SUBSCRIBER_RETRY};
    return unless keys %$retries;

    my $h = $self->harness or return;
    my $client = $h->client;

    for my $peer (keys %$retries) {
        my $entry = $retries->{$peer};
        my @queue = @{$entry->{pending} // []};
        $entry->{pending} = [];

        my $peer_gone = 0;
        for my $i (0 .. $#queue) {
            my $payload = $queue[$i];
            my $ok      = eval { $client->send_message($peer, $payload); 1 };
            my $err     = $@;

            next if $ok;

            my $peer_alive = eval { $client->peer_exists($peer) };
            unless ($peer_alive) {
                warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
                $peer_gone = 1;
                last;
            }

            # Peer is still on the bus but the send failed again.
            # Keep this payload (and anything after it we have not
            # sent yet) for the next tick so we do not reorder the
            # stream or drop messages just because the bus is
            # momentarily backed up.
            push @{$entry->{pending}} => @queue[$i .. $#queue];
            last;
        }

        if ($peer_gone) {
            delete $self->{+SUBSCRIBERS}->{$peer};
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
        elsif (!@{$entry->{pending}}) {
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
    }

    return;
}

# Push a snapshot of the named run's State out to subscribers AND
# trigger run-finalization if the run is now complete. This replaces
# the round-trip via run_state_update IPC that RunService used to
# drive: subscribers still see one snapshot per state change, just
# sourced locally instead of over the bus.
sub broadcast_run_state {
    my ($self, $run_id) = @_;
    my $h = $self->harness or return;
    my $rstate = $h->{Test2::Harness2::RUN_STATES()}->{$run_id} or return;
    my $data   = $rstate->TO_JSON;
    $self->notify_state($run_id, $data);

    my ($run) = grep { $_->run_id eq $run_id } @{$h->{Test2::Harness2::QUEUE()} // []};
    $h->_finalize_run_if_complete($run) if $run;
    return;
}

# Peer-drop hook. Called by the harness's run_on_peer_delta when a
# subscriber leaves the bus without a clean unsubscribe. Drops both
# the registration and any queued retries; harmless on peers that
# were never subscribed.
sub forget_peer {
    my ($self, $peer) = @_;
    return unless defined $peer && length $peer;
    return unless exists $self->{+SUBSCRIBERS}->{$peer};

    warn "Test2::Harness2: subscriber '$peer' left without unsubscribing\n";
    delete $self->{+SUBSCRIBERS}->{$peer};
    delete $self->{+SUBSCRIBER_RETRY}->{$peer};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::StateBroadcaster - Subscriber registry + run-state fanout for the harness.

=head1 DESCRIPTION

The state broadcaster owns the harness's subscriber registry and the
fan-out logic that pushes per-run state snapshots to subscribed peers.
Consumers (typically the C<test> command) subscribe over IPC to be
told when run state changes; the harness mirrors run state in-process
and the broadcaster delivers a full snapshot to every interested peer
on every state transition.

A per-peer retry queue holds payloads whose initial send failed while
the peer is still registered on the bus; L</drain_retries> is called
each service tick to flush them. Peers that have left the bus are
dropped from the registry along with any queued retries.

The harness constructs one StateBroadcaster during its own C<init>
and holds a strong reference to it. The broadcaster holds a weakened
backref to the harness via L<Test2::Harness2::Role::Subsystem> so it
can reach the harness's IPC client, the live run queue, the per-run
C<Run::State> map, and the terminal-snapshot map for completed runs.

This object does not own the harness's emit-side event stream;
C<emit_service_event> stays on the harness because it writes the
harness's own service-event log, not the subscriber fanout channel.

=head1 METHODS

=over 4

=item $resp = $sb->subscribe($payload, $msg)

Register or extend interest for the IPC peer named by C<< $msg->from >>.
Validates every requested run id against the harness's live queue and
terminal-snapshot map and rejects unknown ids. If C<state> was set, an
initial snapshot is sent for each freshly-added run. Returns
C<< { ok => 1 } >> on success or C<< { ok => 0, error => "..." } >> on
any failure.

=item $resp = $sb->unsubscribe($payload, $msg)

Drop the IPC peer named by C<< $msg->from >> from the registry and
discard any queued retries. Idempotent.

=item $sb->notify_state($run_id, $run_data)

Push the supplied run-state hashref to every subscriber that asked
for state events on C<$run_id>.

=item $sb->send_snapshot($peer, run_id => $run_id)

Send a one-off snapshot of C<$run_id> to C<$peer>. The snapshot is
sourced from the live C<Run::State> if the run is in the queue, from
the terminal C<COMPLETED_RUNS> entry otherwise; unknown run ids are
silent no-ops.

=item $sb->send($peer, $payload)

Deliver one message to C<$peer>. On send failure, asks the bus
whether the peer is still registered; if it is, the payload is queued
on the per-peer retry queue (capped at C<SUBSCRIBER_RETRY_CAP> with
FIFO trimming + a one-time warn). If the peer is gone, drops the
registration immediately.

=item $sb->drain_retries

Drain every per-peer retry queue once. Per payload, the same
peer-alive gate applies: keep retrying while the peer is on the bus,
drop the peer (and the rest of its queue) once C<peer_exists> reports
it gone. Called from the harness once per service tick.

=item $sb->broadcast_run_state($run_id)

Snapshot C<$run_id> from the harness's C<Run::State> map, fan it out
to interested subscribers, and ask the harness to finalize the run if
the snapshot is terminal.

=item $sb->forget_peer($peer)

Drop C<$peer> from both the subscriber registry and any queued
retries. Warns when called for a peer that was actually subscribed
(so unexpected departures still leave a trace); no-op for peers that
were never registered.

=item $h = $sb->harness

Returns the harness reference, or C<undef> when the harness has gone
away. Inherited from L<Test2::Harness2::Role::Subsystem>.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::Run::State>.

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
