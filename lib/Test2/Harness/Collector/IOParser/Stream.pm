package Test2::Harness::Collector::IOParser::Stream;
use strict;
use warnings;

our $VERSION = '2.000000';

use Test2::Harness::Collector::TapParser qw/parse_stdout_tap parse_stderr_tap/;

use parent 'Test2::Harness::Collector::IOParser';
use Test2::Harness::Util::HashBase qw{};

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream = $io->{stream};
    my $text   = $io->{line};

    my $facets = $stream eq 'stdout' ? parse_stdout_tap($text) : parse_stderr_tap($text);

    if ($facets) {
        $event->{facet_data} = $facets;
        return;
    }

    return $self->SUPER::parse_stream_line(@_);
}

sub parse_process_action {
    my $self = shift;
    my ($io, $event) = @_;

    $self->SUPER::parse_process_action(@_);

    my $action = $io->{action} or return;
    my $data   = $io->{$action};

    if ($action eq 'exit') {
        $event->{facet_data}->{harness_job_exit} = {
            exit  => $data->{exit}->{all},
            stamp => $data->{stamp},
        };
    }
}


1;
