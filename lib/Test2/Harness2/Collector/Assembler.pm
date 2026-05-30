package Test2::Harness2::Collector::Assembler;
use v5.38;

our $VERSION = '2.000000';

use Test2::Harness2::Util qw/hub_truth/;
use Test2::Harness2::Event;

use Object::HashBase qw{
    <emit_stray
    -nested
    -subtests
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Processor';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Assembler - Collector processor that coalesces
scattered subtest events into one nested authoritative event.

=head1 DESCRIPTION

The first processor in the collector pipeline for test jobs. Subtests reach the
collector in three shapes: buffered Stream2 events arrive already nested (a
C<parent> facet whose C<children> hold the subtest's events); buffered TAP
arrives as an C<ok ... {> open, the child lines, and a C<}> close; and
unbuffered/streamed subtests arrive as a stream of depth-stamped events with no
explicit close. The assembler turns all three into one canonical form: a single
event per top-level subtest carrying every descendant nested inside
C<parent.children>, emitted when the subtest closes.

Correlation is by nesting depth and arrival order -- events carry no ids. A
subtest opens on a C<harness.subtest_start> marker (registered at C<depth + 1>);
deeper events accumulate as its children; the subtest closes when an event at a
shallower depth arrives (or, for buffered TAP, on the explicit
C<harness.subtest_end>). Because the only correlation is depth on a single
ordered stream, one assembler instance handles every depth -- it does not
recurse.

By default the assembler emits B<only> the authoritative events, so a recorded
events file never contains a child event that will also appear inside a subtest
event. With L</emit_stray> enabled it B<also> emits each subtest-belonging event
standalone, in arrival order, marked C<harness_auditor.stray = 1>, plus a
synthetic C<harness.subtest_started> announcement at each subtest's open. These
stray events exist purely so a live consumer can render a subtest before it
closes; they are noise in an after-the-fact log, hence off by default.

The downstream auditor ignores stray events and audits the authoritative ones.

=head1 ATTRIBUTES

=over 4

=item emit_stray

When true, also emit the standalone realtime copies of subtest-belonging events
(each marked C<harness_auditor.stray>) and the synthetic subtest-start
announcements. Default false: only authoritative events are emitted.

=item nested

The nesting depth this assembler treats as its own top level. C<0> (the
default); set internally, not part of the public interface.

=item subtests

Internal per-depth buffer of open subtests. Not part of the public interface.

=back

=cut

sub init ($self) {
    $self->{+NESTED} //= 0;
    $self->{+SUBTESTS} = {};
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item @events = $assembler->process_event($event)

Take one parsed event and return the events to pass downstream: pass-through
events as they arrive, one assembled C<parent.children> event per subtest when
it closes, and -- when L</emit_stray> is set -- the standalone realtime copies
and subtest-start announcements.

=back

=cut

sub process_event ($self, $event) {
    my $f  = $event->facet_data;
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    return $event if $hf->{buffered};

    my $is_ours = $nested == $self->{+NESTED};

    return $event unless $is_ours || $f->{from_tap};

    return $event if $f->{from_tap}    && $f->{from_tap}{source} eq 'STDERR';
    return $event if $f->{from_stream} && $f->{from_stream}{source} eq 'STDERR';

    return $self->_subtest_start($event, $f, $nested, $is_ours)
        if $f->{harness} && $f->{harness}{subtest_start};

    ($event, $f) = $self->_orphan_subtest_end_recovery($event, $f)
        if $f->{from_tap}
        && $f->{harness}
        && $f->{harness}{subtest_end}
        && !keys %{$self->{+SUBTESTS}};

    my @closed = $self->_close_deeper_subtests($event, $nested);

    if ($is_ours) {
        # Authoritative: emit the event itself (unless it is a closing brace),
        # followed by any subtest events its arrival just closed.
        my @out;
        push @out => $event
            unless $f->{harness} && $f->{harness}{subtest_end};
        push @out => @closed;
        return @out;
    }

    # A child event of an open subtest: buffer a clean copy for assembly, and
    # -- only when stray emission is enabled -- emit a marked realtime copy.
    my $st = $self->{+SUBTESTS}{$nested} ||= {};
    push @{$st->{children}} => {%$f};

    my @out;
    push @out => $self->_stray_copy($event) if $self->{+EMIT_STRAY};
    push @out => @closed;
    return @out;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item @events = $self->_subtest_start($event, $f, $nested, $is_ours)

Begin buffering a subtest: store its opening event at C<depth + 1>. Returns the
synthetic C<harness.subtest_started> announcement (only for our own level), or
nothing.

=item $copy = $self->_stray_copy($event)

Return a distinct copy of C<$event> marked C<harness_auditor.stray = 1>, the
realtime-only standalone form of a subtest child event. A separate object so
marking it never touches the clean copy buffered for assembly.

=item ($event, $f) = $self->_orphan_subtest_end_recovery($event, $f)

Rewrite a stray TAP subtest-end (a C<}> with no open subtest) into an info-only
event so it is recorded as plain output rather than a broken close.

=item @events = $self->_close_deeper_subtests($event, $nested)

Close every buffered subtest deeper than C<$nested>, rolling each into a nested
C<parent.children> event. A closed subtest is folded into its parent's children
when the parent is deeper than our level, or emitted as an authoritative event
when the parent is our level.

=back

=cut

sub _subtest_start ($self, $event, $f, $nested, $is_ours) {
    my $st = $self->{+SUBTESTS}{$nested + 1} ||= {};
    $st->{event} = $event;
    $event->clear_compressed_form;

    # The subtest-start announcement is a realtime-only hint; emit it only when
    # stray emission is enabled, and only at our own level.
    return unless $is_ours && $self->{+EMIT_STRAY};

    return Test2::Harness2::Event->new(
        facet_data => {
            harness_auditor => {stray           => 1},
            harness         => {subtest_started => 1, nested => $nested},
            (defined $f->{trace} ? (trace => {%{$f->{trace}}}) : ()),
        },
    );
}

sub _stray_copy ($self, $event) {
    my $f = $event->facet_data;

    # A distinct event so marking it stray never contaminates the clean copy
    # already buffered as a subtest child.
    my $copy = Test2::Harness2::Event->new(
        facet_data => {
            %$f,
            harness_auditor => {%{$f->{harness_auditor} || {}}, stray => 1},
        },
    );
    $copy->clear_compressed_form;

    return $copy;
}

sub _orphan_subtest_end_recovery ($self, $event, $f) {
    $event->clear_compressed_form;

    $f = {
        %$f,
        harness_auditor => {added_by_auditor => 1},
        parent          => undef,
        trace           => undef,
        harness         => {%{$f->{harness} || {}}, subtest_end => undef},
        info            => [
            @{$f->{info} || []},
            {
                details      => $f->{from_tap}{details},
                tag          => $f->{from_tap}{source} || 'STDOUT',
                from_harness => 1,
            },
        ],
    };

    return (Test2::Harness2::Event->new(facet_data => $f), $f);
}

sub _close_deeper_subtests ($self, $event, $nested) {
    my $sts = $self->{+SUBTESTS};

    my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;
    return unless @close;

    my @out;
    for my $n (@close) {
        my $st = delete $sts->{$n};
        my $se = $st->{event} || $event;

        my $fd = $se->facet_data;
        $fd->{parent}{hid}      ||= $n;
        $fd->{parent}{children} ||= $st->{children};
        $fd->{harness}{closed_by} = $event;
        $se->clear_compressed_form;

        my $pn = $n - 1;

        if ($st->{event}) {
            push @{$sts->{$pn}{children}} => $fd if $pn > $self->{+NESTED};
            push @out                     => $se if $pn == $self->{+NESTED};
        }
        else {
            push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
        }
    }

    return @out;
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
