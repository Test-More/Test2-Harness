package Test2::Harness2::Collector::Monitor;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;

use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <pipe
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

Test2::Harness2::Collector::Monitor - Consume a collector notification pipe and
track the state of every collector writing to it.

=head1 DESCRIPTION

A monitor reads the notification messages that one or more collector recorders
send over a transition pipe (see
L<Test2::Harness2::Collector::Recorder>). B<Any number of collectors -- tests
and services alike -- may write to the same pipe>; the monitor keys all of its
state on the per-message collector C<uuid>, so messages from different
collectors interleave freely.

L</poll> reads whatever is available without blocking, folds each message into
per-collector state, and returns the payloads it read. The monitor can then be
queried for the tests and services it has seen, each one's status, events
file, and (once complete) final result. It also answers "what changed since I
last asked" questions -- L</new_collectors>, L</new_failing>,
L</new_test_exits>, and friends -- each of which drains and returns the uuids
that entered that state since the previous call.

The underlying L<Atomic::Pipe> is exposed via L</pipe> so a caller can add its
read handle to an L<IO::Select> and block until there is something to
L</poll>.

=head1 SYNOPSIS

    use IO::Select;
    use Test2::Harness2::Collector::Monitor;

    my $mon = Test2::Harness2::Collector::Monitor->new(pipe => $read_pipe);
    my $sel = IO::Select->new($mon->pipe->rh);

    while (1) {
        $sel->can_read;           # block until a message is available
        my $payloads = $mon->poll;
        last unless @$payloads;   # EOF: every writer closed

        $_ and do_something($_) for $mon->new_test_exits;    # freed slots, ...
    }

=head1 ATTRIBUTES

=over 4

=item pipe (required)

The read-end L<Atomic::Pipe> the collectors write to. The monitor switches it
to non-blocking and enables zstd decompression on construction.

=back

=cut

sub init ($self) {
    my $pipe = $self->{+PIPE}
        or croak "pipe is a required attribute";

    $pipe->blocking(0);
    apply_atomic_pipe_compression($pipe);

    $self->{+COLLECTORS} = {};
    $self->{+PROXIES}    = {};
    $self->{+REPLAY}     = {};

    $self->{+PENDING_NEW}        = [];
    $self->{+PENDING_FAILING}    = [];
    $self->{+PENDING_DIAGNOSING} = [];
    $self->{+PENDING_COMPLETED}  = [];
    $self->{+PENDING_EXITS}      = [];
    $self->{+PENDING_FINALIZED}  = [];

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item poll

=item @payloads = $mon->poll

=item $count = $mon->poll

=item $mon->poll

Read every message currently available on the pipe without blocking and update
internal state. Context-sensitive: in list context returns the decoded
payloads (in arrival order); in scalar context returns the number of messages
read; in void context returns nothing (skipping the bookkeeping a caller that
only wants the state update does not need).

=item @uuids = $mon->collectors

=item @uuids = $mon->tests

=item @uuids = $mon->services

The uuids of all collectors seen, or just the tests / just the services.

=item collector

=item $state = $mon->collector($uuid)

The state hashref for one collector (or C<undef>): C<uuid>, C<category>
(C<test> / C<service>), C<name>, C<events_file>, C<try>, C<run_uuid> (the run
it belongs to, or undef for a global collector), C<status> (C<running> /
C<complete> / C<finalized>), the C<failing> / C<diagnosing> flags, and
C<final_state> once seen.

=item $status = $mon->status($uuid)

=item $path = $mon->events_file($uuid)

=item $state = $mon->final_state($uuid)

Conveniences for individual fields of L</collector>.

=back

=cut

sub poll ($self) {
    my $pipe = $self->{+PIPE};

    my $void = !defined wantarray;

    my @payloads;
    my $count = 0;
    while (defined(my $msg = $pipe->read_message)) {
        my $payload;
        my $ok = eval { $payload = decode_json($msg); 1 };
        unless ($ok) {
            warn "monitor: could not decode a pipe message: $@\n";
            next;
        }

        $count++;
        push @payloads => $payload unless $void;
        $self->_process($payload);

        my $uuid = $payload->{facet_data}{harness_collector}{uuid};
        next unless defined $uuid;
        $self->_forward($uuid, $msg);
        $self->_retain_for_replay($uuid, $msg);
    }

    return if $void;
    return wantarray ? @payloads : $count;
}

sub collectors ($self) { return keys %{$self->{+COLLECTORS}} }

sub tests ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'test' }
        keys %{$self->{+COLLECTORS}};
}

sub services ($self) {
    return grep { ($self->{+COLLECTORS}{$_}{category} // '') eq 'service' }
        keys %{$self->{+COLLECTORS}};
}

sub collector   ($self, $uuid) { return $self->{+COLLECTORS}{$uuid} }
sub status      ($self, $uuid) { my $c = $self->{+COLLECTORS}{$uuid} or return undef; return $c->{status} }
sub events_file ($self, $uuid) { my $c = $self->{+COLLECTORS}{$uuid} or return undef; return $c->{events_file} }
sub final_state ($self, $uuid) { my $c = $self->{+COLLECTORS}{$uuid} or return undef; return $c->{final_state} }

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

=item $mon->add_proxy($name, $pipe, global => 1)

=item $mon->add_proxy($name, $pipe, run_uuid => $uuid)

=item $mon->add_proxy($name, $pipe, run_uuids => \@uuids)

Register a proxy: messages the monitor reads from then on are also forwarded,
verbatim, to C<$pipe> (an L<Atomic::Pipe> write end, switched to zstd here).
Any number of proxies may be registered under distinct names.

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
the same filter -- the messages of every collector that has not yet completed,
in arrival order. A downstream L<Test2::Harness2::Collector::Monitor> reading
C<$pipe> therefore reconstructs the matching state this monitor holds.

=item $pipe = $mon->remove_proxy($name)

Stop forwarding to (and return the pipe of) the proxy registered under
C<$name>.

=back

=cut

sub add_proxy ($self, $name, $pipe, %opts) {
    croak "a proxy name is required" unless defined $name && length $name;
    croak "a proxy pipe is required" unless $pipe;

    apply_atomic_pipe_compression($pipe);
    my $proxy = $self->{+PROXIES}{$name} = {pipe => $pipe, filter => $self->_build_filter(%opts)};

    # Replay the in-flight collectors the proxy wants, so its consumer does not
    # miss the start (and any failing/diagnosing) it needs to track state.
    for my $uuid (sort keys %{$self->{+REPLAY}}) {
        next unless $self->_proxy_wants($proxy, $uuid);
        $self->_write_proxy($pipe, $_) for @{$self->{+REPLAY}{$uuid}};
    }

    return;
}

sub remove_proxy ($self, $name) {
    my $proxy = delete $self->{+PROXIES}{$name} or return undef;
    return $proxy->{pipe};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item @uuids = $self->_drain($slot)

Return and clear one of the pending change lists.

=item $self->_process($payload)

Fold one decoded message into per-collector state and the pending change
lists, keyed by the message's collector uuid.

=item $self->_forward($uuid, $msg)

Forward one raw message (for collector C<$uuid>) to every registered proxy
whose filter accepts it.

=item $filter = $self->_build_filter(%opts)

Turn C<add_proxy>'s C<global> / C<run_uuid> / C<run_uuids> options into a
filter hashref, or C<undef> when no options were given (forward everything).

=item $bool = $self->_proxy_wants($proxy, $uuid)

Whether a proxy's filter accepts the collector C<$uuid> (always true for an
unfiltered proxy).

=item $self->_retain_for_replay($uuid, $msg)

Keep the raw message in the per-collector replay buffer while the collector is
in flight, so a proxy added later can be caught up; drop the buffer once the
collector is complete or finalized (it will not be replayed).

=item $self->_write_proxy($pipe, $msg)

Write one raw message to a single proxy pipe, warning (not dying) on failure.

=back

=cut

sub _forward ($self, $uuid, $msg) {
    my $proxies = $self->{+PROXIES};
    return unless %$proxies;

    for my $proxy (values %$proxies) {
        next unless $self->_proxy_wants($proxy, $uuid);
        $self->_write_proxy($proxy->{pipe}, $msg);
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

sub _proxy_wants ($self, $proxy, $uuid) {
    my $filter = $proxy->{filter} or return 1;    # no filter -> forward all

    my $c   = $self->{+COLLECTORS}{$uuid};
    my $run = $c ? $c->{run_uuid} : undef;

    return 1 if $filter->{global} && !defined $run;
    return 1 if defined $run      && $filter->{run_uuids}{$run};
    return 0;
}

sub _retain_for_replay ($self, $uuid, $msg) {
    my $status = $self->{+COLLECTORS}{$uuid}{status} // '';
    if ($status eq 'complete' || $status eq 'finalized') {
        delete $self->{+REPLAY}{$uuid};
        return;
    }

    push @{$self->{+REPLAY}{$uuid}} => $msg;
    return;
}

sub _write_proxy ($self, $pipe, $msg) {
    warn "monitor: proxy forward failed: $@\n"
        unless eval { $pipe->write_message($msg); 1 };
    return;
}

sub _drain ($self, $slot) {
    my $list = $self->{$slot};
    $self->{$slot} = [];
    return @$list;
}

sub _process ($self, $payload) {
    my $fd   = $payload->{facet_data}   or return;
    my $hc   = $fd->{harness_collector} or return;
    my $uuid = $hc->{uuid} // return;

    my $c = $self->{+COLLECTORS}{$uuid};
    unless ($c) {
        $c = $self->{+COLLECTORS}{$uuid} = {
            uuid       => $uuid,
            status     => 'running',
            failing    => 0,
            diagnosing => 0,
        };
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
        push @{$self->{+PENDING_FINALIZED}} => $uuid;
        return;
    }

    return;
}

sub _process_transition ($self, $c, $state, $hc) {
    if ($state eq 'starting') {
        $c->{name}        = $hc->{name};
        $c->{events_file} = $hc->{events_file};
        $c->{try}         = $hc->{try};
        $c->{run_uuid}    = $hc->{run_uuid};
        $c->{category}    = defined $hc->{try} ? 'test' : 'service';
        $c->{status}      = 'running';
        return;
    }

    if ($state eq 'failing') {
        return if $c->{failing};
        $c->{failing} = 1;
        push @{$self->{+PENDING_FAILING}} => $c->{uuid};
        return;
    }

    if ($state eq 'diagnosing') {
        return if $c->{diagnosing};
        $c->{diagnosing} = 1;
        push @{$self->{+PENDING_DIAGNOSING}} => $c->{uuid};
        return;
    }

    if ($state eq 'completed') {
        $c->{status} = 'complete';
        push @{$self->{+PENDING_COMPLETED}} => $c->{uuid};
        push @{$self->{+PENDING_EXITS}} => $c->{uuid}
            if ($c->{category} // '') eq 'test';
        return;
    }

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
