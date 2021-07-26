package Test2::Harness::UI::Util::ImportModes;
use strict;
use warnings;

use Scalar::Util qw/blessed reftype/;
use Carp qw/croak/;

use Importer Importer => 'import';

my %MODES = (
    summary  => 5,
    qvf      => 10,
    qvfd     => 15,
    qvfds    => 17,
    complete => 20,
);

%MODES = (
    %MODES,
    map {$_ => $_} values %MODES,
);

our @EXPORT_OK = qw/event_in_mode record_all_events mode_check/;

our %EXPORT_ANON = (
    '%MODES' => \%MODES,
);

sub mode_check {
    my ($got, @want) = @_;
    my $g = $MODES{$got} // croak "Invalid mode: $got";

    for my $want (@want) {
        my $w = $MODES{$want} // croak "Invalid mode: $want";
        return 1 if $g == $w;
    }

    return 0;
}

sub _get_mode {
    my %params = @_;

    my $run  = $params{run};
    my $mode = $params{mode};

    croak "must specify either 'mode' or 'run'" unless $run || $mode;

    # Normalize
    $mode = $MODES{$mode} // $mode;
    croak "Invalid mode: $mode" unless $mode =~ m/^\d+$/;

    return $mode;
}

sub record_all_events {
    my %params = @_;

    my $mode = _get_mode(%params);

    my $job            = $params{job};
    my $fail           = $params{fail};
    my $is_harness_out = $params{is_harness_out};

    croak "must specify either 'job' or 'fail' and 'is_harness_out'"
        unless $job || (defined($fail) && defined($is_harness_out));

    # Always true in complete mode
    return 1 if $mode >= $MODES{complete};

    # No events in summary
    return 0 if $mode <= $MODES{summary};

    # Job 0 (harness output) is kept in all non-summary modes
    $is_harness_out //= $job->is_harness_out;
    return 1 if $is_harness_out;

    # QVF and QVFD are all events when failing
    $fail //= $job->fail;
    return 1 if $fail && $mode >= $MODES{qvf};

    return 0;
}

sub event_in_mode {
    my %params = @_;

    my $event = $params{event} or croak "'event' is required";

    my $record_all = $params{record_all_events} // record_all_events(%params);
    return 1 if $record_all;

    # Only look for diag and similar for QVFD and higher
    my $mode = _get_mode(%params);
    return 0 unless $mode >= $MODES{qvfd};

    my $cols = _get_event_columns($event);

    return 1 if $mode == $MODES{qvfds} && $cols->{is_subtest} && $cols->{nested} == 0;
    return 1 if $cols->{is_diag};
    return 1 if $cols->{is_harness};
    return 1 if $cols->{is_time};

    return 0;
}

sub _get_event_columns {
    my ($event) = @_;

    return { $event->get_columns } if blessed($event) && $event->can('get_columns');
    return $event if (reftype($event) // '') eq 'HASH';

    croak "Invalid event: $event";
}

1;
