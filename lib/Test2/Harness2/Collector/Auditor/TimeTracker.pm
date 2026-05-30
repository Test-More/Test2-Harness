package Test2::Harness2::Collector::Auditor::TimeTracker;
use v5.38;

our $VERSION = '2.000000';

use Object::HashBase qw{
    <start
    <stop
    <first
    <last
    <complete
    <_totals
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor::TimeTracker - Track a test's phase
timings from its event stream.

=head1 DESCRIPTION

Accumulates timing data while an event stream is processed and reports the
duration of each phase of a test run:

=over 4

=item startup - launch to the first test event.

=item events - first test event to the last.

=item cleanup - last test event to process exit.

=item total - launch to process exit.

=back

Stamps are read from facets, not from any top-level event field: test events
carry C<trace.stamp>, and the synthetic process-exit event
(C<harness_process_exit>) carries C<start_stamp> (the launch time) and
C<stamp> (the reap time). Feed every event through L</process>, then read
L</totals>.

=head1 SYNOPSIS

    my $tt = Test2::Harness2::Collector::Auditor::TimeTracker->new;

    my $assertions = 0;
    for my $event (@events) {
        $assertions++ if $event->facet_data->{assert};
        $tt->process($event, $assertions);
    }

    my $totals = $tt->totals if $tt->useful;

=head1 ATTRIBUTES

All state (the C<start> / C<stop> / C<first> / C<last> stamps) is filled in by
L</process>; the tracker takes no construction arguments.

=cut

=head1 PUBLIC METHODS

=cut

=over 4

=item process

=item $tt->process($event)

=item $tt->process($event, $assertion_count)

Fold one event into the tracker. The process-exit event sets the launch /
reap stamps and ends accumulation; test events (those with a C<trace>) move
the first / last marks. A plan seen after at least one assertion ends the
event phase, so trailing teardown output is not counted as a test event.

=item $bool = $tt->useful

True when more than one of the four stamps was captured (i.e. there is at
least one phase to report).

=item totals

=item $totals = $tt->totals

Hashref of C<startup> / C<events> / C<cleanup> / C<total> raw-second
durations, each present only when both of its endpoint stamps are known.

=item $data = $tt->source

The raw stamps the totals derive from (C<start> / C<stop> / C<first> /
C<last>).

=item $data = $tt->data_dump

C<< { totals => ..., source => ... } >>.

=back

=cut

sub process ($self, $event, $assertion_count = 0) {
    delete $self->{+_TOTALS};

    my $f = $event->facet_data;

    if (my $px = $f->{harness_process_exit}) {
        $self->{+STOP}     = $px->{stamp};
        $self->{+START}    = $px->{start_stamp} if defined $px->{start_stamp};
        $self->{+COMPLETE} = 1;
        return;
    }

    return if $self->{+COMPLETE};

    if ($f->{control} && $f->{control}{phase} && $f->{control}{phase} eq 'END') {
        $self->{+COMPLETE} = 1;
        return;
    }

    my $stamp = $f->{trace} ? $f->{trace}{stamp} : undef;
    if (defined $stamp) {
        $self->{+LAST} = $stamp;
        $self->{+FIRST} //= $stamp;
    }

    # A plan after assertions ends the event phase, but the plan itself still
    # counts (its stamp was just recorded above).
    $self->{+COMPLETE} = 1
        if $assertion_count && $f->{plan} && !$f->{plan}{none};

    return;
}

sub useful ($self) {
    my @got = grep { defined $self->{$_} } START, FIRST, LAST, STOP;
    return @got > 1 ? 1 : 0;
}

my @FIELDS  = qw/startup events cleanup total/;
my %SOURCES = (
    startup => [FIRST, START],
    events  => [LAST,  FIRST],
    cleanup => [STOP,  LAST],
    total   => [STOP,  START],
);

sub totals ($self) {
    return $self->{+_TOTALS} if $self->{+_TOTALS};

    my %out;
    for my $field (@FIELDS) {
        my ($end_key, $beg_key) = @{$SOURCES{$field}};
        my ($end,     $beg)     = ($self->{$end_key}, $self->{$beg_key});
        next unless defined $end && defined $beg;
        $out{$field} = $end - $beg;
    }

    return $self->{+_TOTALS} = \%out;
}

sub source ($self) {
    return {
        start => $self->{+START},
        stop  => $self->{+STOP},
        first => $self->{+FIRST},
        last  => $self->{+LAST},
    };
}

sub data_dump ($self) {
    return {totals => $self->totals, source => $self->source};
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
