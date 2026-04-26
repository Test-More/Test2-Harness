package Test2::Harness2::Util::EventEmitter;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Atomic::Pipe;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::IPC qw/apply_atomic_pipe_compression/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <stdout_pipe
    <stderr_pipe
};

sub init {
    my $self = shift;

    # Accept either a pre-built Atomic::Pipe or any filehandle (typeglob
    # ref, IO::Handle, etc.) that Atomic::Pipe->from_fh can dup. Anything
    # else we promote to a mixed-mode Atomic::Pipe by duping the write
    # side. When the caller passes neither, default to wrapping STDOUT
    # (and STDERR iff T2_HARNESS2_PIPE_COUNT advertises separate pipes --
    # see the collector's _child_env_overrides / _interpose_child for
    # where that env var is published). The most common shape is exactly
    # that: emit on STDOUT, sync-mark on STDERR.
    $self->{+STDOUT_PIPE} = $self->_as_atomic_pipe($self->{+STDOUT_PIPE} // \*STDOUT);

    if (exists $self->{+STDERR_PIPE}) {
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe($self->{+STDERR_PIPE})
            if defined $self->{+STDERR_PIPE};
    }
    else {
        my $pipe_count = $ENV{T2_HARNESS2_PIPE_COUNT} // 1;
        $self->{+STDERR_PIPE} = $self->_as_atomic_pipe(\*STDERR) if $pipe_count > 1;
    }
}

sub _as_atomic_pipe {
    my $self = shift;
    my ($in) = @_;

    return $in if blessed($in) && $in->isa('Atomic::Pipe');

    # Match the collector's reader-side compression config so framed
    # write_message / write_burst output decodes on the other end.
    # Plain print writes (e.g. the user's STDOUT text) are not
    # touched by Atomic::Pipe's compression and reach a non-perl
    # downstream untouched. from_fh does not take constructor-time
    # compression kwargs, so we configure it post-construction.
    my $apipe = Atomic::Pipe->from_fh('>&=', $in);
    $apipe->set_mixed_data_mode();
    apply_atomic_pipe_compression($apipe);
    return $apipe;
}

# Process-wide cached emitter for the default STDOUT/STDERR pair. Most
# harness code wants exactly one of these per process -- wrapping STDOUT
# twice would dup the file descriptor under us, and every caller is
# writing the same events/sync markers to the same collector anyway. The
# cache is keyed on $$ so a fork invalidates cleanly: the child's first
# std() call sees the stale pid, builds a fresh instance from its own
# (possibly swap_io'd) STDOUT/STDERR, and stores that under the new pid.
{
    my $CACHED;
    my $CACHED_PID;

    sub std {
        my $class = shift;
        return $CACHED if $CACHED && defined($CACHED_PID) && $CACHED_PID == $$;
        $CACHED_PID = $$;
        return $CACHED = $class->new;
    }
}

sub emit_event {
    my ($self, %fields) = @_;

    my $event_id = gen_uuid();
    my $stamp    = time;

    my $event = {
        event_id   => $event_id,
        stamp      => $stamp,
        pid        => $$,
        facet_data => {
            harness => {
                event_id => $event_id,
                stamp    => $stamp,
                %fields,
            },
        },
    };

    return $self->emit_raw($event);
}

sub emit_raw {
    my ($self, $event) = @_;

    # Make sure the top-level event_id and the harness facet event_id agree.
    # If only one is set, propagate it; if neither, generate one; if both are
    # set to different values, refuse to emit -- that is always a caller bug.
    my $top     = $event->{event_id};
    my $harness = $event->{facet_data}{harness}{event_id};
    if (defined($top) && defined($harness) && $top ne $harness) {
        croak "event_id mismatch: top-level '$top' vs harness facet '$harness'";
    }
    my $event_id = $top // $harness // gen_uuid();
    $event->{event_id} = $event_id;
    $event->{facet_data}{harness}{event_id} = $event_id;

    my $json = encode_json($event);
    $self->{+STDOUT_PIPE}->write_message($json);

    if (my $se = $self->{+STDERR_PIPE}) {
        $se->write_message(qq/{"event_id":"$event_id"}/);
    }

    return $event_id;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::EventEmitter - Write structured events to an Atomic::Pipe without loading Test2::API

=head1 SYNOPSIS

    use Test2::Harness2::Util::EventEmitter;

    # Most common shape: emit to STDOUT, sync-mark on STDERR when the
    # surrounding collector says STDERR is a separate mixed-mode pipe.
    my $emitter = Test2::Harness2::Util::EventEmitter->new;
    $emitter->emit_event(kind => 'lifecycle', note => 'starting up');

    # Explicit: pre-built Atomic::Pipe halves (useful in tests where you
    # need to read the output, or for callers that also use the pipes
    # elsewhere).
    use Atomic::Pipe;
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    # Plain filehandles are promoted for you.
    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => \*STDOUT,
        stderr_pipe => \*STDERR,
    );

=head1 DESCRIPTION

A small standalone helper that writes structured events to an
L<Atomic::Pipe> in mixed-data mode using the same wire format that
L<Test2::Formatter::Stream2/_send_event> uses.  This allows services and
harness infrastructure code to emit lifecycle events that an existing
collector can read and process -- without loading
C<Test2::Formatter::Stream2> or integrating with the L<Test2::API> hub.

Each call to L</emit_event> writes one atomic JSON message burst to the
stdout pipe.  The collector on the other end reads it with
C<< $pipe->get_line_burst_or_data() >> and sees it as a C<message>-type
item, exactly the same as events produced by the Stream2 formatter.

=head1 ATTRIBUTES

Both attributes accept one of: a pre-built L<Atomic::Pipe> in
C<mixed_data_mode>, any filehandle that L<Atomic::Pipe/from_fh> can
promote (C<\*STDOUT>, an L<IO::Handle>, etc.), or C<undef> to take the
default.  When a bare filehandle is supplied the emitter duplicates its
write side and flips the new pipe into mixed-data mode, so callers do
not have to pre-wrap the handle themselves.

=over 4

=item stdout_pipe

The pipe the main JSON event bursts land on.  Defaults to wrapping
C<\*STDOUT>.

=item stderr_pipe

The pipe the tiny C<{"event_id":"..."}> sync marker lands on when set.
When neither given nor C<undef>, the default is determined from
C<$ENV{T2_HARNESS2_PIPE_COUNT}>: the collector sets that env var to C<2>
when STDOUT and STDERR are separate mixed-mode pipes, and to C<1> when
the two are merged onto the same pipe (see
L<Test2::Harness2::Collector>).  The emitter therefore wraps
C<\*STDERR> only when the env var advertises separate pipes; otherwise
it leaves the slot empty to avoid writing a duplicate marker onto a
merged pipe.  Pass C<undef> explicitly to opt out of sync markers.

=back

=head1 METHODS

=over 4

=item $emitter = Test2::Harness2::Util::EventEmitter->std

Return the process-wide cached emitter for the default STDOUT/STDERR
pair.  The first call in a process instantiates it via L</new> with no
arguments (so it obeys the same C<T2_HARNESS2_PIPE_COUNT> defaulting
described under L</stderr_pipe>) and caches it; every subsequent call
returns that same instance.  Fork-safe: the cache is keyed on C<$$>,
and after a fork the child's first C<std> call sees the stale pid and
rebuilds from its own -- possibly redirected -- STDOUT/STDERR.

Use this anywhere you want the "just emit to the collector on STDOUT
with a sync marker on STDERR" shape.  Callers that need a distinct
emitter (e.g. writing to caller-owned pipes) should call L</new>
instead.

=item $event_id = $emitter->emit_event(%fields)

Build a harness-facet event, encode it as JSON, write it to
L</stdout_pipe>, and optionally write the STDERR sync marker to
L</stderr_pipe>.  C<%fields> are merged into the C<harness> facet.
Returns the UUID assigned to the event.

=item $event_id = $emitter->emit_raw($event_hashref)

Write a pre-built event hashref as-is: encode to JSON, write the burst
to L</stdout_pipe>, and if L</stderr_pipe> is set write
C<{"event_id":"..."}> to it.  Returns C<< $event->{event_id} >>.  Use
this when the caller has already assembled the full event shape
(e.g. L<Test2::Formatter::Stream2>) and does not need the harness-facet
wrapping that L</emit_event> provides.

=back

=head2 ORDERING NOTE

C<Atomic::Pipe> in C<mixed_data_mode> does B<not> guarantee FIFO ordering
between plain C<print>/C<warn> writes and C<write_message> calls on the
same pipe fd, even when both come from the same process.  This is a
kernel-level property: a raw C<print> and an immediately following
C<write_message> may arrive at the reader in either order under scheduler
pressure.

Consequently, callers of this module must B<not> interleave raw C<print>
calls on the same underlying fd (e.g. C<STDOUT>) with C<emit_*> calls and
then rely on strict arrival-order at the reader.  The sync-marker contract
(every STDOUT event is paired with a STDERR sync marker) allows the
Collector to order STDOUT events relative to STDERR lines, but it cannot
reorder items that have already been delivered out of sequence within the
same stream.

In practice this limitation only matters in contrived test scenarios that
drive a tight C<print> / C<write_message> loop on the same pipe fd.  Normal
test processes (via C<Test2::Formatter::Stream2>) and normal service code
produce coarser interleaving and are not affected.

See C<ARCHITECTURE.md> Addendum A (GH#389) for the full investigation
notes, including the Collector read-loop analysis.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
