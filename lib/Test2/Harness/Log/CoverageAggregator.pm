package Test2::Harness::Log::CoverageAggregator;
use strict;
use warnings;

our $VERSION = '1.000038';

use Test2::Harness::Util::HashBase qw/<coverage_data/;

sub process_event {
    my $self = shift;
    my ($e) = @_;

    return unless $e;
    return unless keys %$e;

    my $job_id = $e->{job_id} // 0;
    my $set = $self->{+COVERAGE_DATA}->{$job_id} //= {};

    if ($e->{facet_data}->{coverage}) {
        push @{$set->{files}} => @{$e->{facet_data}->{coverage}->{files}};
    }

    if (my $end = $e->{facet_data}->{harness_job_end}) {
        $set->{test} //= $end->{rel_file};
    }

    if (my $start = $e->{facet_data}->{harness_job_start}) {
        $set->{test} //= $start->{rel_file};
    }
}

sub coverage {
    my $self = shift;

    my $coverage = {};

    for my $job (values %{$self->{+COVERAGE_DATA} // {}}) {
        my $test  = $job->{test}  or next;
        my $files = $job->{files} or next;
        next unless @$files;

        push @{$coverage->{$_}} => $test for @$files;
    }

    return $coverage;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Log::CoverageAggregator - Module for aggregating coverage data
from a strema of events.

=head1 DESCRIPTION

This module takes a stream of events and produces aggregated coverage data.

=head1 SYNOPSIS

    use Test2::Harness::Log::CoverageAggregator;

    my $agg = Test2::Harness::Log::CoverageAggregator->new();

    while (my $e = $log->next_event) {
        $agg->process_event($e);
    }

    my $coverage = $agg->coverage;

    use Test2::Harness::Util::JSON qw/encode_json/;
    open(my $fh, '>', "coverage.json") or die "$!";
    print $fh encode_json($coverage);
    close($fh);

=head1 METHODS

=over 4

=item $agg->process_event($event)

Process the event, aggregating any coverage info it may contain.

=item $haashref = $agg->coverage()

Produce a hashref of all aggregated coverage data:

    {
        'test_file_a.t' => [
            'lib/MyModule1.pm',
            'lib/MyModule2.pm',
            ...,
        ],
        'test_file_b.t' => [
            'share/css/foo.css',
            'lib/AnotherModule.pm',
            ...
        ],
        ...,
    }

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
