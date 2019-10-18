package Test2::Harness::Auditor::TimeTracker;
use strict;
use warnings;

our $VERSION = '0.001100';

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
    my ($event, $f, $hf, $assertion_count) = @_;

    my $stamp = $event->{stamp} or return;
    my $id    = $event->{event_id} // 'N/A';

    $f  //= $event->{facet_data};
    $hf //= hub_truth($f);


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
