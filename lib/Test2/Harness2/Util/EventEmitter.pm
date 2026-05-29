package Test2::Harness2::Util::EventEmitter;
use v5.38;

our $VERSION = '2.000000';

use Scalar::Util qw/blessed/;
use Atomic::Pipe;

use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <stdout_pipe
    <stderr_pipe
    <ordinal
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::EventEmitter - Write structured events to an
Atomic::Pipe without loading Test2::API.

=head1 DESCRIPTION

A small standalone helper that writes structured events to an
L<Atomic::Pipe> in mixed-data mode using the same wire format that
L<Test2::Formatter::Stream2> uses. Services and harness infrastructure code
use it to emit lifecycle events that an existing collector can read without
loading the L<Test2::API> hub.

Each call to L</emit_event> writes one atomic JSON message burst (a JSON
hash) to the stdout pipe and -- when L</stderr_pipe> is set -- a tiny
C<[pid, ordinal]> sync marker (a JSON array) to both pipes so the collector
can order STDOUT events relative to interleaved STDERR text. The marker is
distinguished from an event by being an array rather than a hash, and is used
only for ordering -- it is never recorded. C<pid> plus the per-emitter
C<ordinal> stays unique even when a forked child emits on an inherited pipe.

=head1 SYNOPSIS

    use Test2::Harness2::Util::EventEmitter;

    my $emitter = Test2::Harness2::Util::EventEmitter->new;
    $emitter->emit_event(kind => 'lifecycle', note => 'starting up');

=head1 ATTRIBUTES

Both attributes accept one of: a pre-built L<Atomic::Pipe> in
C<mixed_data_mode>, any filehandle that L<Atomic::Pipe/from_fh> can promote
(C<\*STDOUT>, an L<IO::Handle>, etc.), or C<undef> to take the default.

=over 4

=item stdout_pipe

The pipe the main JSON event bursts land on. Defaults to wrapping
C<\*STDOUT>.

=item stderr_pipe

The pipe a copy of the C<[pid, ordinal]> sync marker lands on when set. When
neither given nor C<undef>, the default is determined from
C<$ENV{T2_HARNESS2_PIPE_COUNT}>: C<2> means STDOUT and STDERR are separate
mixed-mode pipes; C<1> means they are merged onto the same pipe and the
emitter leaves the slot empty to avoid writing a duplicate marker.

=back

=cut

sub init ($self) {
    $self->{+ORDINAL} = 0;

    $self->{+STDOUT_PIPE} = $self->_as_atomic_pipe($self->{+STDOUT_PIPE} // \*STDOUT);

    if (exists $self->{+STDERR_PIPE}) {
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe($self->{+STDERR_PIPE})
            if defined $self->{+STDERR_PIPE};
    }
    else {
        my $pipe_count = $ENV{T2_HARNESS2_PIPE_COUNT} // 1;
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe(\*STDERR) if $pipe_count > 1;
    }

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $emitter = Test2::Harness2::Util::EventEmitter->std

Process-wide cached emitter for the default STDOUT / STDERR pair. The first
call instantiates it via C<new> with no arguments; every subsequent call
returns that instance. Fork-safe: the cache is keyed on C<$$>, so after a
fork the child's first C<std> call sees the stale pid and rebuilds from its
own (possibly redirected) STDOUT / STDERR.

=back

=cut

{
    my $CACHED;
    my $CACHED_PID;

    sub std ($class) {
        return $CACHED if $CACHED && defined($CACHED_PID) && $CACHED_PID == $$;
        $CACHED_PID = $$;
        return $CACHED = $class->new;
    }
}

=over 4

=item emit_event

=item $event_id = $emitter->emit_event(%fields)

Build a harness-facet event, encode it as JSON, write it to L</stdout_pipe>,
and optionally write the STDERR sync marker to L</stderr_pipe>. C<%fields>
are merged into the C<harness> facet. Returns the UUID assigned to the event.

=item $ordinal = $emitter->emit_raw($event_hashref)

Write a pre-built event hashref as-is (no identifier or sync field is stamped
onto it): encode to JSON and write the burst to L</stdout_pipe>. Then -- when
L</stderr_pipe> is set -- write a single sync marker C<[pid, ordinal]> to both
pipes so the collector can order STDOUT events against interleaved STDERR
text. The marker is a JSON array (events are JSON hashes), which is how the
collector tells them apart; it is used only for ordering and never recorded.
Returns the ordinal assigned to the event.

=back

=cut

sub emit_event ($self, %fields) {
    my $event = {
        facet_data => {
            harness => {%fields},
        },
    };

    return $self->emit_raw($event);
}

sub emit_raw ($self, $event) {
    my $ordinal = $self->{+ORDINAL}++;

    $self->{+STDOUT_PIPE}->write_message(encode_json($event));

    if (my $se = $self->{+STDERR_PIPE}) {
        my $sync = encode_json([$$, $ordinal]);
        $self->{+STDOUT_PIPE}->write_message($sync);
        $se->write_message($sync);
    }

    return $ordinal;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $pipe = $self->_as_atomic_pipe($in)

Promote C<$in> to an L<Atomic::Pipe> in mixed-data mode with the harness's
zstd compression defaults. Returns C<$in> unchanged when it already is an
L<Atomic::Pipe>.

=back

=cut

sub _as_atomic_pipe ($self, $in) {
    return $in if blessed($in) && $in->isa('Atomic::Pipe');

    my $apipe = Atomic::Pipe->from_fh('>&=', $in);
    $apipe->set_mixed_data_mode();
    apply_atomic_pipe_compression($apipe);
    return $apipe;
}

1;

__END__

=pod

=head2 ORDERING NOTE

C<Atomic::Pipe> in C<mixed_data_mode> does B<not> guarantee FIFO ordering
between plain C<print> / C<warn> writes and C<write_message> calls on the
same pipe fd, even when both come from the same process. The sync-marker
contract (every STDOUT event is paired with a STDERR sync marker) lets the
collector order STDOUT events relative to STDERR lines, but it cannot
reorder items that have already been delivered out of sequence within the
same stream.

In practice this only matters in contrived test scenarios that drive a tight
C<print> / C<write_message> loop on the same pipe fd. Normal test processes
via L<Test2::Formatter::Stream2> are not affected.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
