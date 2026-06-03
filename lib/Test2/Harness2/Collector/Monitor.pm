package Test2::Harness2::Collector::Monitor;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Compress::Zstd ();
use IO::Select     ();
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Socket qw/open_unix_listen connect_unix write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use constant DEFAULT_COMPLETED_TTL => 300;

use Object::HashBase qw{
    <listen
    <socket_path
    <listen_sock
    <select
    <conns
    <completed_ttl
    +system
    +system_frame
    +runs
    +jobs
    +collectors
    +proxies
    +replay
    +pending_new
    +pending_failing
    +pending_diagnosing
    +pending_completed
    +pending_exits
    +pending_finalized
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Monitor - Consume collector transition messages and
track the state of every collector.

=head1 DESCRIPTION

A monitor folds the notification messages that flow through the transition
pipeline into state. It tracks three kinds of entity:

=over 4

=item *

B<runs> -- announced by the harness (via C<announce>), keyed by C<run_uuid>,
moving C<queued> -> C<running> -> C<complete>.

=item *

B<jobs> -- announced by the harness at queue time (with the Run::Job spec), then
updated by the test's collector (which shares the C<job_uuid>), keyed by
C<job_uuid>.

=item *

B<collectors> -- service / global collectors, keyed by collector C<uuid>. A
test collector folds into its job rather than appearing here.

=back

Collector recorders (see L<Test2::Harness2::Collector::Recorder>) send
per-collector messages keyed on the collector C<uuid> that rides on every one.
The monitor can be queried for the runs, jobs, and collectors it has seen, each
one's status, events file, config, and (once complete) final result, plus "what
changed since I last asked" deltas -- L</new_collectors>, L</new_failing>,
L</new_test_exits>, and friends -- each of which drains and returns the uuids
that entered that state since the previous call. Completed entities are reaped
on a TTL (C<sweep> / L</completed_ttl>).

The monitor runs in one of two modes:

=over 4

=item Managed (C<listen>)

The monitor owns a listening unix socket. Each collector's recorder connects to
it and writes self-contained zstd frames; one accepted connection per collector
means no two collectors' frames ever interleave. L</poll> -- which never blocks
-- accepts pending connections, reads ready ones, splits frames, and folds each
C<transition> envelope into state. The monitor's file descriptors are exposed
via L</io_handles> so a caller can add them to its own L<IO::Select> loop, and
the listen path via L</socket_path>.

=item Unmanaged (no C<listen>)

Some other component owns the socket(s). It reads, decompresses, decodes, and
unwraps frames itself, then hands the monitor already-decoded transition
payloads via L</feed> (or raw frames via L</feed_frame>, which also forwards to
proxies). In this mode L</poll> does nothing.

=back

=head1 SYNOPSIS

    use IO::Select;
    use Test2::Harness2::Collector::Monitor;

    # Managed: the monitor listens; recorders connect to its socket path.
    my $mon = Test2::Harness2::Collector::Monitor->new(listen => 1);
    my $path = $mon->socket_path;    # hand this to recorder transition_sockets

    while (1) {
        IO::Select->new($mon->io_handles)->can_read;    # block until ready
        $mon->poll;                                     # never blocks

        $_ and do_something($_) for $mon->new_test_exits;    # freed slots, ...
    }

    # Unmanaged: feed already-decoded payloads from elsewhere.
    my $mon2 = Test2::Harness2::Collector::Monitor->new;
    $mon2->feed($decoded_transition_payload);

=head1 ATTRIBUTES

=over 4

=item listen

Optional. C<1> to have the monitor create a listening socket at a path it picks
(see L</socket_path>); a path string to listen on that exact path. The monitor
unlinks a stale path, binds, and listens at construction, and unlinks its own
socket on L</close> / C<DESTROY>. Omit entirely for unmanaged mode.

=item completed_ttl

Seconds a completed run / finalized job / finalized collector is retained before
C<sweep> removes it. Defaults to 300. Set to 0 to disable reaping.

=back

=cut

sub init ($self) {
    $self->{+RUNS}       = {};
    $self->{+JOBS}       = {};
    $self->{+COLLECTORS} = {};
    $self->{+PROXIES}    = {};
    $self->{+REPLAY}     = {};
    $self->{+CONNS}      = {};

    $self->{+COMPLETED_TTL} //= DEFAULT_COMPLETED_TTL;

    $self->{+PENDING_NEW}        = [];
    $self->{+PENDING_FAILING}    = [];
    $self->{+PENDING_DIAGNOSING} = [];
    $self->{+PENDING_COMPLETED}  = [];
    $self->{+PENDING_EXITS}      = [];
    $self->{+PENDING_FINALIZED}  = [];

    if (my $listen = $self->{+LISTEN}) {
        my $path =
            ($listen eq '1' || $listen eq 1)
            ? $self->_default_socket_path
            : $listen;

        $self->{+SOCKET_PATH} = $path;
        $self->{+LISTEN_SOCK} = open_unix_listen($path);
        $self->{+LISTEN_SOCK}->blocking(0);

        my $sel = IO::Select->new;
        $sel->add($self->{+LISTEN_SOCK});
        $self->{+SELECT} = $sel;
    }

    return;
}

sub _default_socket_path ($self) {
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    return "$dir/transitions.sock";
}

=head1 PUBLIC METHODS

=cut

=over 4

=item poll

=item @payloads = $mon->poll

=item $count = $mon->poll

=item $mon->poll

Managed mode only (a no-op in unmanaged mode). Never blocks: accept any pending
connections, read every connection that is ready, split complete frames, and
fold each C<transition> envelope into internal state. A connection at EOF is
reaped (cleanup only -- the C<harness_collector_finalized> message arrives
before the close). Context-sensitive: in list context returns the decoded
transition payloads (in arrival order); in scalar context returns the number of
messages processed; in void context returns nothing.

=item socket_path

=item $path = $mon->socket_path

Managed mode: the path of the listening socket (the one given, or the one the
monitor picked for C<< listen =E<gt> 1 >>). C<undef> in unmanaged mode.

=item io_handles

=item @handles = $mon->io_handles

Managed mode: the monitor's current file descriptors -- the listening socket
plus every live accepted connection -- so a caller can add them to its own
L<IO::Select>. The set changes as connections come and go, so re-fetch it each
loop. Empty in unmanaged mode.

=item feed

=item $mon->feed($payload)

Unmanaged mode: fold one already-decoded transition C<$payload> (the envelope's
C<payload>, i.e. C<< {facet_data =E<gt> ...} >>) into state. Does not forward to
proxies (there is no frame to forward).

=item feed_frame

=item $payload = $mon->feed_frame($frame)

Unmanaged mode with a raw frame in hand: decode the frame, fold the
C<transition> payload into state, and forward the verbatim frame to proxies.
Returns the payload, or C<undef> for a non-transition frame.

=item $payload = $mon->announce(\%facet_data)

Managed mode: emit a synthetic transition carrying C<\%facet_data> (e.g. a
C<harness_run> or C<harness_job> facet). Folds it into local state, forwards it
to proxies, and retains it for replay -- exactly as a frame read off a socket.
Used by the harness to publish run / job lifecycle updates.

=item $mon->sweep

=item $mon->sweep($now)

Remove every run / job / collector that reached its terminal state more than
L</completed_ttl> seconds ago. A no-op when C<completed_ttl> is 0. Each monitor
(the managed one and every downstream one) sweeps its own state independently.

=item @uuids = $mon->collectors

=item @uuids = $mon->tests

=item @uuids = $mon->services

The uuids of every collector-backed entity (tests live in the jobs table,
services/global in the collectors table), or just the tests / just the services.

=item @uuids = $mon->runs

=item @uuids = $mon->jobs

The uuids of all tracked runs / jobs.

=item $snapshot = $mon->system_load

The latest system load snapshot (a hashref: C<cpu_pct>, C<ncpu>, C<load_avg>,
C<mem_total>, C<mem_available>, C<mem_used>, C<mem_pct>, C<stamp>), or C<undef>
if none has arrived. Published by the harness from a C<harness_system> message;
broadcast to every subscriber unfiltered and kept as a single latest value.

=item collector

=item $state = $mon->collector($uuid)

The state hashref for one collector-backed entity (or C<undef>). A test uuid
resolves to its job entry, otherwise to a collector entry. Fields: C<uuid> /
C<job_uuid>, C<category> (C<test> / C<service>), C<name>, C<events_file>,
C<try>, C<run_uuid>, C<config> (the spawn config), C<status> (C<queued> /
C<running> / C<complete> / C<finalized>), the C<failing> / C<diagnosing> flags,
C<final_state> once seen, and (for jobs) the Run::Job C<spec>.

=item $state = $mon->run($run_uuid)

The state hashref for one run (or C<undef>): C<run_uuid>, C<state> (C<queued> /
C<running> / C<complete>), C<job_uuids>, C<job_count>, C<completed>, C<passed>,
C<failed>, and C<pass> (at complete).

=item $state = $mon->job($job_uuid)

The state hashref for one job (or C<undef>); same shape as L</collector> for a
test entry.

=item $status = $mon->status($uuid)

=item $path = $mon->events_file($uuid)

=item $state = $mon->final_state($uuid)

Conveniences for individual fields of L</collector>.

=back

=cut

sub poll ($self) {
    my $void = !defined wantarray;

    my $sel = $self->{+SELECT};
    return ($void ? undef : (wantarray ? () : 0)) unless $sel;    # unmanaged: nothing to poll

    # Accept any pending connections first.
    while (my $conn = $self->{+LISTEN_SOCK}->accept) {
        $conn->blocking(0);
        $sel->add($conn);
        $self->{+CONNS}{$conn} = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    }

    my @payloads;
    my $count = 0;

    for my $fh ($sel->can_read(0)) {
        next if $fh == $self->{+LISTEN_SOCK};
        my $fb = $self->{+CONNS}{$fh} or next;

        my $buf = '';
        my $n   = sysread($fh, $buf, 65536);

        # undef: would-block / transient -- try again next poll.
        next unless defined $n;

        # 0: EOF. Connection closed; reap it (cleanup only, not a state signal).
        if ($n == 0) {
            $sel->remove($fh);
            delete $self->{+CONNS}{$fh};
            close($fh);
            next;
        }

        $fb->push_bytes($buf);
        for my $rec ($fb->drain) {
            my $payload = $self->_handle_frame($rec);
            next unless defined $payload;
            $count++;
            push @payloads => $payload unless $void;
        }
    }

    return if $void;
    return wantarray ? @payloads : $count;
}

sub io_handles ($self) {
    my $sel = $self->{+SELECT} or return ();
    return $sel->handles;
}

sub feed ($self, $payload) {
    $self->_process($payload);
    return;
}

sub feed_frame ($self, $frame) {
    my $payload = Compress::Zstd::decompress($frame);
    croak "monitor: feed_frame given an undecodable frame"
        unless defined $payload;
    return $self->_handle_frame({frame => $frame, payload => $payload});
}

# Every collector-backed entity: tests live in JOBS, services/global in
# COLLECTORS. A test's collector and its job share one uuid and one entry.
sub collectors ($self) { return (keys %{$self->{+JOBS}}, keys %{$self->{+COLLECTORS}}) }

sub tests ($self) {
    return (
        keys %{$self->{+JOBS}},
        grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'test' } keys %{$self->{+COLLECTORS}},
    );
}

sub services ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'service' }
        keys %{$self->{+COLLECTORS}};
}

sub runs ($self) { return keys %{$self->{+RUNS}} }
sub jobs ($self) { return keys %{$self->{+JOBS}} }

sub system_load ($self) { return $self->{+SYSTEM} }

sub run ($self, $uuid) { return $self->{+RUNS}{$uuid} }
sub job ($self, $uuid) { return $self->{+JOBS}{$uuid} }

# A test uuid resolves to its job entry; otherwise to a collector entry.
sub collector   ($self, $uuid) { return $self->{+JOBS}{$uuid} // $self->{+COLLECTORS}{$uuid} }
sub status      ($self, $uuid) { my $c = $self->collector($uuid) or return undef; return $c->{status} }
sub events_file ($self, $uuid) { my $c = $self->collector($uuid) or return undef; return $c->{events_file} }
sub final_state ($self, $uuid) { my $c = $self->collector($uuid) or return undef; return $c->{final_state} }

=over 4

=item new_collectors

=item @uuids = $mon->new_collectors

=item new_failing

=item @uuids = $mon->new_failing

=item @uuids = $mon->new_diagnosing

=item @uuids = $mon->new_completed

=item new_test_exits

=item @uuids = $mon->new_test_exits

=item @uuids = $mon->new_finalized

Drain-on-call change lists: each returns the collector uuids that entered the
named state since the previous call to that method, then forgets them.
C<new_collectors> reports collectors seen for the first time (their events
file is available by then); C<new_test_exits> reports tests whose process has
exited (the C<completed> transition), which the scheduler uses to free a slot.

=item close

=item $mon->close

Managed mode: close the listening socket and every accepted connection, and
unlink the socket path. Called automatically on C<DESTROY>. A no-op in
unmanaged mode.

=back

=cut

sub new_collectors ($self) { return $self->_drain(PENDING_NEW) }
sub new_failing    ($self) { return $self->_drain(PENDING_FAILING) }
sub new_diagnosing ($self) { return $self->_drain(PENDING_DIAGNOSING) }
sub new_completed  ($self) { return $self->_drain(PENDING_COMPLETED) }
sub new_test_exits ($self) { return $self->_drain(PENDING_EXITS) }
sub new_finalized  ($self) { return $self->_drain(PENDING_FINALIZED) }

=over 4

=item $mon->add_proxy($name, $pipe)

=item $mon->add_proxy($name, $target, global => 1)

=item $mon->add_proxy($name, $target, run_uuid => $uuid)

=item $mon->add_proxy($name, $target, run_uuids => \@uuids)

Register a proxy: frames the monitor reads from then on are also forwarded,
verbatim (no recompression), to C<$target>. C<$target> is either an
already-connected socket handle (used as-is) or a path to a unix socket the
monitor C<connect()>s to. Any number of proxies may be registered under
distinct names.

With no options the proxy receives B<every> message. Options restrict it to
the collectors a consumer cares about, and may be combined:

=over 4

=item global => 1

Forward only B<global> collectors -- those with no C<run_uuid>.

=item run_uuid => $uuid

=item run_uuids => \@uuids

Forward only collectors whose C<run_uuid> is among those given.

=back

C<global =E<gt> 1> plus a run filter forwards both. The run_uuids need not
correspond to any collector yet -- matching ones that arrive later are
forwarded.

So a proxy added mid-run does not see collectors half-way through their
lifecycle, C<add_proxy> first replays -- to the new proxy only, and subject to
the same filter -- the frames of every collector that has not yet completed,
in arrival order. A downstream L<Test2::Harness2::Collector::Monitor> reading
C<$target> therefore reconstructs the matching state this monitor holds.

=item $sock = $mon->remove_proxy($name)

Stop forwarding to (and return the socket of) the proxy registered under
C<$name>.

=back

=cut

sub add_proxy ($self, $name, $target, %opts) {
    croak "a proxy name is required"   unless defined $name && length $name;
    croak "a proxy target is required" unless defined $target;

    my $sock  = ref($target) ? $target : connect_unix($target);
    my $proxy = $self->{+PROXIES}{$name} = {sock => $sock, filter => $self->_build_filter(%opts)};

    # Replay the in-flight entities the proxy wants (runs, jobs, collectors), so
    # its consumer does not miss the start it needs to reconstruct state.
    for my $id (sort keys %{$self->{+REPLAY}}) {
        my $buf = $self->{+REPLAY}{$id};
        next unless $self->_proxy_filter_match($proxy, $buf->{run});
        $self->_write_proxy($sock, $_) for @{$buf->{frames}};
    }

    # The latest system-load snapshot goes to every proxy, unfiltered.
    $self->_write_proxy($sock, $self->{+SYSTEM_FRAME}) if defined $self->{+SYSTEM_FRAME};

    return;
}

sub remove_proxy ($self, $name) {
    my $proxy = delete $self->{+PROXIES}{$name} or return undef;
    return $proxy->{sock};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $path = $self->_default_socket_path

Pick a unique unix socket path in a fresh temp directory, for C<listen =E<gt> 1>.

=item $payload = $self->_handle_frame($rec)

Process one decoded frame C<< {frame =E<gt> $raw, payload =E<gt> $json} >>:
decode the C<< {type, payload} >> envelope, fold a C<transition> payload into
state, forward the verbatim frame to proxies, and retain it for replay. Returns
the transition payload, or C<undef> for a non-transition or undecodable frame.

=item @uuids = $self->_drain($slot)

Return and clear one of the pending change lists.

=item $self->_process($payload)

Fold one decoded message into state. Dispatches on the facet present:
C<harness_run> to C<_process_run>, C<harness_job> to C<_process_job>, and a
C<harness_collector> to C<_process_collector>.

=item $self->_process_run($run_facet)

Merge a C<harness_run> facet into the C<runs> table (creating the entry on first
sight), stamping completion time when it reaches C<complete>.

=item $self->_process_job($job_facet)

Seed / update a C<jobs> table entry from a C<harness_job> facet (Run::Job spec,
run association).

=item $self->_process_collector($fd, $hc)

Fold a collector message into the right table: a known job uuid updates its job
entry, any other uuid a collector entry. Fires C<new_collectors> the first time
a collector message arrives for the entity, then applies the transition / final
state / finalization.

=item $self->_process_transition($entry, $state, $hc)

Apply one C<starting> / C<failing> / C<diagnosing> / C<completed> transition to a
job or collector entry (the C<starting> message also lands name, events file,
try, run_uuid, config, and category).

=item ($id, $run_uuid, $terminal) = $self->_route_info($facet_data)

The entity id and run association used to forward and replay a message, plus
whether the message leaves the entity in a terminal (no-longer-replayed) state.

=item $self->_forward($run_uuid, $frame)

Forward one raw frame to every registered proxy whose filter accepts the
message's run association.

=item $filter = $self->_build_filter(%opts)

Turn C<add_proxy>'s C<global> / C<run_uuid> / C<run_uuids> options into a
filter hashref, or C<undef> when no options were given (forward everything).

=item $bool = $self->_proxy_filter_match($proxy, $run_uuid)

Whether a proxy's filter accepts a message with the given run association
(always true for an unfiltered proxy).

=item $self->_retain_for_replay($id, $run_uuid, $frame, $terminal)

Keep the raw frame in the per-entity replay buffer while the entity is in flight,
so a proxy added later can be caught up; drop the buffer once the entity is
terminal.

=item $self->_write_proxy($sock, $frame)

Write one raw frame to a single proxy socket, warning (not dying) on failure.

=back

=cut

sub _handle_frame ($self, $rec) {
    my $envelope;
    my $ok = eval { $envelope = decode_json($rec->{payload}); 1 };
    unless ($ok) {
        warn "monitor: could not decode a transition frame: $@\n";
        return undef;
    }

    return undef unless ($envelope->{type} // '') eq 'transition';

    my $payload = $envelope->{payload};
    $self->_process($payload);

    # System load is a global singleton, not a lifecycle entity: broadcast it to
    # every proxy regardless of filter, and keep only the latest frame for
    # replay so a new subscriber immediately gets current load.
    if ($payload->{facet_data}{harness_system}) {
        $self->{+SYSTEM_FRAME} = $rec->{frame};
        $self->_write_proxy($_->{sock}, $rec->{frame}) for values %{$self->{+PROXIES}};
        return $payload;
    }

    my ($id, $run_uuid, $terminal) = $self->_route_info($payload->{facet_data});
    if (defined $id) {
        $self->_forward($run_uuid, $rec->{frame});
        $self->_retain_for_replay($id, $run_uuid, $rec->{frame}, $terminal);
    }

    return $payload;
}

sub announce ($self, $facet_data) {
    my $envelope = encode_json({type => 'transition', payload => {facet_data => $facet_data}});
    return $self->_handle_frame({frame => compress_blob($envelope), payload => $envelope});
}

sub sweep ($self, $now = undef) {
    my $ttl = $self->{+COMPLETED_TTL} or return;    # 0 / undef disables reaping
    $now //= time;

    for my $table (RUNS(), JOBS(), COLLECTORS()) {
        my $h = $self->{$table};
        for my $id (keys %$h) {
            my $done = $h->{$id}{done_stamp} // next;
            delete $h->{$id} if ($now - $done) > $ttl;
        }
    }

    return;
}

sub _forward ($self, $run_uuid, $frame) {
    my $proxies = $self->{+PROXIES};
    return unless %$proxies;

    for my $proxy (values %$proxies) {
        next unless $self->_proxy_filter_match($proxy, $run_uuid);
        $self->_write_proxy($proxy->{sock}, $frame);
    }

    return;
}

sub _build_filter ($self, %opts) {
    my @runs;
    push @runs => $opts{run_uuid}     if defined $opts{run_uuid};
    push @runs => @{$opts{run_uuids}} if $opts{run_uuids};

    my $global = $opts{global} ? 1 : 0;

    # No filter options: the proxy gets everything.
    return undef unless $global || @runs;

    return {global => $global, run_uuids => {map { $_ => 1 } @runs}};
}

sub _proxy_filter_match ($self, $proxy, $run_uuid) {
    my $filter = $proxy->{filter} or return 1;    # no filter -> forward all

    return 1 if $filter->{global} && !defined $run_uuid;
    return 1 if defined $run_uuid && $filter->{run_uuids}{$run_uuid};
    return 0;
}

sub _retain_for_replay ($self, $id, $run_uuid, $frame, $terminal) {
    if ($terminal) {
        delete $self->{+REPLAY}{$id};
        return;
    }

    my $buf = $self->{+REPLAY}{$id} //= {run => $run_uuid, frames => []};
    $buf->{run} = $run_uuid if defined $run_uuid;
    push @{$buf->{frames}} => $frame;

    return;
}

sub _write_proxy ($self, $sock, $frame) {
    warn "monitor: proxy forward failed: $@\n"
        unless eval { write_frame($sock, $frame); 1 };
    return;
}

sub _drain ($self, $slot) {
    my $list = $self->{$slot};
    $self->{$slot} = [];
    return @$list;
}

sub _process ($self, $payload) {
    my $fd = $payload->{facet_data} or return;

    if (my $sys = $fd->{harness_system}) { $self->{+SYSTEM} = $sys; return; }

    return $self->_process_run($fd->{harness_run}) if $fd->{harness_run};
    return $self->_process_job($fd->{harness_job}) if $fd->{harness_job};

    my $hc = $fd->{harness_collector} or return;
    return $self->_process_collector($fd, $hc);
}

sub _process_run ($self, $r) {
    my $uuid = $r->{run_uuid} // return;

    my $run = $self->{+RUNS}{$uuid} //= {run_uuid => $uuid, state => 'queued'};

    # Merge: each message carries only the fields that changed.
    for my $k (qw/state job_uuids job_count completed passed failed pass/) {
        $run->{$k} = $r->{$k} if exists $r->{$k};
    }

    $run->{done_stamp} //= time if ($run->{state} // '') eq 'complete';

    return;
}

sub _process_job ($self, $j) {
    my $uuid = $j->{job_uuid} // return;

    my $job = $self->{+JOBS}{$uuid} //= {
        job_uuid   => $uuid,
        status     => 'queued',
        failing    => 0,
        diagnosing => 0,
        category   => 'test',
    };

    $job->{run_uuid} = $j->{run_uuid} if exists $j->{run_uuid};
    $job->{spec}     = $j->{spec}     if exists $j->{spec};

    return;
}

sub _process_collector ($self, $fd, $hc) {
    my $uuid = $hc->{uuid} // return;

    # Dispatch: a known job uuid folds into its job; otherwise a collector.
    my $c = $self->{+JOBS}{$uuid};
    unless ($c) {
        $c = $self->{+COLLECTORS}{$uuid} //= {
            uuid       => $uuid,
            status     => 'running',
            failing    => 0,
            diagnosing => 0,
            category   => 'service',
        };
    }

    # new_collectors fires once, the first time a collector message arrives for
    # the entity (the 'starting' transition, by which point name / events_file /
    # config are available) -- not at the harness's job-queued announce.
    unless ($c->{seen_collector}) {
        $c->{seen_collector} = 1;
        push @{$self->{+PENDING_NEW}} => $uuid;
    }

    if (my $transition = $fd->{harness_state_transition}) {
        $self->_process_transition($c, $transition->{state}, $hc);
        return;
    }

    if (my $final = $fd->{harness_final_state}) {
        $c->{final_state} = $final;
        return;
    }

    if ($fd->{harness_collector_finalized}) {
        $c->{status} = 'finalized';
        $c->{done_stamp} //= time;
        push @{$self->{+PENDING_FINALIZED}} => $uuid;
        return;
    }

    return;
}

sub _process_transition ($self, $c, $state, $hc) {
    if ($state eq 'starting') {
        $c->{name}        = $hc->{name}        if exists $hc->{name};
        $c->{events_file} = $hc->{events_file} if exists $hc->{events_file};
        $c->{try}         = $hc->{try}         if exists $hc->{try};
        $c->{run_uuid}    = $hc->{run_uuid}    if exists $hc->{run_uuid};
        $c->{config}      = $hc->{config}      if exists $hc->{config};
        $c->{category}    = defined $hc->{try} ? 'test' : 'service';
        $c->{status}      = 'running';
        return;
    }

    if ($state eq 'failing') {
        return if $c->{failing};
        $c->{failing} = 1;
        push @{$self->{+PENDING_FAILING}} => $c->{uuid} // $c->{job_uuid};
        return;
    }

    if ($state eq 'diagnosing') {
        return if $c->{diagnosing};
        $c->{diagnosing} = 1;
        push @{$self->{+PENDING_DIAGNOSING}} => $c->{uuid} // $c->{job_uuid};
        return;
    }

    if ($state eq 'completed') {
        $c->{status} = 'complete';
        my $id = $c->{uuid} // $c->{job_uuid};
        push @{$self->{+PENDING_COMPLETED}} => $id;
        push @{$self->{+PENDING_EXITS}} => $id
            if ($c->{category} // '') eq 'test';
        return;
    }

    return;
}

sub _route_info ($self, $fd) {
    if (my $r = $fd->{harness_run}) {
        my $id = $r->{run_uuid};
        return (undef, undef, 0) unless defined $id;
        my $terminal = (($self->{+RUNS}{$id}{state} // '') eq 'complete') ? 1 : 0;
        return ($id, $id, $terminal);
    }

    if (my $j = $fd->{harness_job}) {
        my $id = $j->{job_uuid};
        return (undef, undef,                         0) unless defined $id;
        return ($id,   $self->{+JOBS}{$id}{run_uuid}, 0);                      # a job announce is never terminal
    }

    if (my $hc = $fd->{harness_collector}) {
        my $id = $hc->{uuid};
        return (undef, undef, 0) unless defined $id;
        my $entry  = $self->{+JOBS}{$id} // $self->{+COLLECTORS}{$id};
        my $run    = $entry ? $entry->{run_uuid}       : undef;
        my $status = $entry ? ($entry->{status} // '') : '';
        # A collector/job stops being replayed once it is no longer in flight.
        my $terminal = ($status eq 'complete' || $status eq 'finalized') ? 1 : 0;
        return ($id, $run, $terminal);
    }

    return (undef, undef, 0);
}

sub close ($self) {
    if (my $sel = $self->{+SELECT}) {
        for my $fh ($sel->handles) {
            $sel->remove($fh);
            close($fh);
        }
    }
    $self->{+CONNS} = {};

    if (my $path = $self->{+SOCKET_PATH}) {
        unlink $path if -e $path;
    }

    return;
}

sub DESTROY ($self) {
    $self->close;
    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
