package Test2::Harness::Auditor::TimeTracker;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::Harness::Util qw/hub_truth/;
use Test2::Util::Times qw/render_duration/;

use Test2::Harness::Util::HashBase qw{
    -start -start_id
    -stop  -stop_id
    -first -first_id
    -last  -last_id
    -complete_id

    -_source
    -_totals
};

sub process {
    my $self = shift;
    my ($event, $f, $assertion_count) = @_;

    # Invalidate cache
    delete $self->{+_TOTALS};
    delete $self->{+_SOURCE};

    my $stamp = $event->{stamp} or return;
    my $id    = $event->{event_id} // 'N/A';

    $f  //= $event->{facet_data};

    if ($f->{harness_job_exit}) {
        $self->{+STOP}    = $stamp;
        $self->{+STOP_ID} = $id;
    }

    return if $self->{+COMPLETE_ID};

    if ($f->{harness_job_start}) {
        $self->{+START}    = $stamp;
        $self->{+START_ID} = $id;
    }

    # These events absolutely end the events phase, and do not count as part of
    # it.
    $self->{+COMPLETE_ID} //= $event->{event_id} if $f->{harness_job_exit};
    $self->{+COMPLETE_ID} //= $event->{event_id} if $f->{control} && $f->{control}->{phase} && $f->{control}->{phase} eq 'END';

    return if $self->{+COMPLETE_ID};

    # Plan still counts as 'event' phase, so do not return if we are setting this now
    $self->{+COMPLETE_ID} //= $event->{event_id} if $assertion_count && $f->{plan} && !$f->{plan}->{none};

    return unless $f->{trace}; # Events with traces are "event" phase.

    # Always replace the last, if we got this far.
    $self->{+LAST} = $stamp;
    $self->{+LAST_ID} = $id;

    # Only set the first one once
    return if $self->{+FIRST};
    $self->{+FIRST} = $stamp;
    $self->{+FIRST_ID} = $id;

    return;
}

sub useful {
    my $self = shift;

    my @got = grep { defined $self->{$_} } START, FIRST, LAST, STOP;
    return @got > 1;
}

my @TOTAL_FIELDS = qw/startup events cleanup total/;
my %TOTAL_SOURCES = (
    startup => [FIRST, START],
    events  => [LAST,  FIRST],
    cleanup => [STOP,  LAST],
    total   => [STOP,  START]
);
my %TOTAL_DESC = (
    startup => "Time from launch to first test event.",
    events  => "Time spent generating test events.",
    cleanup => "Time from last test event to test exit.",
    total   => "Total time",
);

sub totals {
    my $self = shift;

    return $self->{+_TOTALS} if $self->{+_TOTALS};

    my $out = {};

    for my $field (@TOTAL_FIELDS) {
        my $sources = $TOTAL_SOURCES{$field} or die "Invalid field: $field";
        my @vals    = @{$self}{@$sources};
        next unless defined($vals[0]) && defined($vals[1]);

        my $delta = $vals[0] - $vals[1];
        $out->{$field} = $delta;
        $out->{"h_$field"} = render_duration($delta);
    }

    return $self->{+_TOTALS} = $out;
}

sub source {
    my $self = shift;

    return $self->{+_SOURCE} if $self->{+_SOURCE};

    my @fields = (
        START, START_ID,
        STOP,  STOP_ID,
        FIRST, FIRST_ID,
        LAST,  LAST_ID,
        COMPLETE_ID,
    );

    my %out;
    @out{@fields} = @{$self}{@fields};

    return $self->{+_SOURCE} = \%out;
}

sub data_dump {
    my $self = shift;

    return {
        totals => $self->totals,
        source => $self->source,
    };
}

sub summary {
    my $self = shift;
    my $totals = $self->totals;

    my $summary = "";
    for my $field (@TOTAL_FIELDS) {
        my $hval  = $totals->{"h_$field"} // next;
        my $title = ucfirst($field);

        $summary .= " | " if $summary;
        $summary .= "$title: $hval";
    }

    return $summary;
}

sub table {
    my $self   = shift;
    my $totals = $self->totals;

    my $table = {
        header => ["Phase", "Time", "Raw", "Explanation"],
        rows   => [],
    };

    for my $field (@TOTAL_FIELDS) {
        my $val   = $totals->{$field} // next;
        my $hval  = $totals->{"h_$field"};
        my $title = ucfirst($field);

        push @{$table->{rows}} => [$title, $hval, $val, $TOTAL_DESC{$field}];
    }

    return $table;
}

sub job_fields {
    my $self = shift;
    my $totals = $self->totals;

    my @out;

    for my $field (@TOTAL_FIELDS) {
        my $val   = $totals->{$field} // next;
        my $hval  = $totals->{"h_$field"};

        my $data = {};
        my $sources = $TOTAL_SOURCES{$field};
        for my $source (@$sources) {
            $data->{$source} = {
                stamp => $self->{$source},
                event_id => $self->{"${source}_id"},
            };
        }

        push @out => {name => "time_$field", details => $hval, raw => $val, data => $data};
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Auditor::TimeTracker - Module that tracks timing data while an
event stream is processed.

=head1 DESCRIPTION

The timetracker module tracks timing data of an event stream. All events for a
given job should be run through a timetracker, which can then give data on how
long the test took in each of several stages.

=over 4

=item startup - Time from launch to first test event.

=item events - Time spent generating test events.

=item cleanup - Time from last test event to test exit.

=item total - Total time.

=back

=head1 SYNOPSIS

    use Test2::Harness::Auditor::TimeTracker;

    my $tracker = Test2::Harness::Auditor::TimeTracker->new();

    my $assert_count = 0;
    for my $event (@events) {
        my $facet_data = $events->facet_data;
        $assert_count++ if $facet_data->{assert};
        $tracker->process($event, $facet_data, $assert_count);
    }

    print $tracker->summary;
    # Startup: 0.00708s | Events: 0.00000s | Cleanup: 0.10390s | Total: 0.11098s

=head1 METHODS

=over 4

=item $tracker->process($event, $facet_data, $assert_count)

=item $tracker->process($event, undef, $assert_count)

TimeTracker builds its state from multiple events, each event should be
processed by this method.

The second argument is optional, if no facet_data is provided it will pull the
facet_data from the event itself. This is mainly a micro-optimization to avoid
calling the C<facet_data()> method on the event multiple times if you have
already called it.

=item $bool = $tracker->useful()

Returns true if there is any useful data to display.

=item $totals = $tracker->totals()

Returns the totals like this:

    {
        # Raw numbers
        startup => ...,
        events  => ...,
        cleanup => ...,
        total   => ...,

        # Human friendly versions
        h_startup => ...,
        h_events  => ...,
        h_cleanup => ...,
        h_total   => ...,
    }

=item $source = $tracker->source()

This method returns the data from which the totals are derived.

    {
        start => ...,    # timestamp of the job starting
        stop  => ...,    # timestamp of the job ending
        first => ...,    # timestamp of the first non-harness event
        last  => ...,    # timestamp of the last non-harness event

        # These are event_id's of the events that provided the above stamps.
        start_id    => ...,
        stop_id     => ...,
        first_id    => ...,
        last_id     => ...,
        complete_id => ...,
    }

=item $data = $tracker->data_dump

This dumps the totals and source data:

    {
        totals => $tracker->totals,
        source => $tracker->source,
    }

=item $string = $tracker->summary

This produces a summary string of the totals data:

    Startup: 0.00708s | Events: 0.00000s | Cleanup: 0.10390s | Total: 0.11098s

Fields that have no data will be ommited from the string.

=item $table = $tracker->table

Returns this structure that is good for use in L<Term::Table>.

    {
        header => ["Phase", "Time", "Raw", "Explanation"],
        rows   => [
            ['startup', $human_readible, $raw, "Time from launch to first test event."],
            ['events',  $human_radible,  $raw, 'Time spent generating test events.'],
            ['cleanup', $human_radible,  $raw, 'Time from last test event to test exit.'],
            ['total',   $human_radible,  $raw, 'Total time.'],
        ],
    }

=item @items = $tracker->job_fields()

This is used to obtain extra data to attach to the job completion event.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
