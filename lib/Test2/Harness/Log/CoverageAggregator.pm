package Test2::Harness::Log::CoverageAggregator;
use strict;
use warnings;

our $VERSION = '1.000047';

use Test2::Harness::Util::HashBase qw/<coverage <job_map/;

sub init {
    my $self = shift;
    $self->{+COVERAGE} //= {};
    $self->{+JOB_MAP}  //= {};
}

sub process_event {
    my $self = shift;
    my ($e) = @_;

    return unless $e;
    return unless keys %$e;

    my $job_map = $self->{+JOB_MAP} //= {};
    my $job_id = $e->{job_id} // 0;

    my $test = $job_map->{$job_id};
    unless ($test) {
        if (my $start = $e->{facet_data}->{harness_job_start}) {
            $test = $start->{rel_file};
        }
        elsif (my $end = $e->{facet_data}->{harness_job_end}) {
            $test = $end->{rel_file};
        }

        $job_map->{$job_id} = $test if $test;
    }

    if (my $c = $e->{facet_data}->{coverage}) {
        die "Got coverage data before test start! (Weird event order?)" unless $test;
        $self->add_coverage($test, $c);
    }
}

sub add_coverage {
    my $self = shift;
    my ($test, $data) = @_;

    my $coverage    = $self->{+COVERAGE}    //= {};
    my $submap      = $coverage->{submap}   //= {};
    my $openmap     = $coverage->{openmap}  //= {};
    my $loadmap     = $coverage->{loadmap}  //= {};
    my $alltestmeta = $coverage->{testmeta} //= {};
    my $testmeta    = $alltestmeta->{$test} //= {};

    if (my $type = $data->{test_type}) {
        $testmeta->{type} = $type;
    }

    if (my $manager = $data->{from_manager}) {
        $testmeta->{manager} = $manager;
    }

    if (my $omap = $data->{openmap}) {
        for my $source (keys %$omap) {
            my $froms = $omap->{$source} || next;
            push @{$openmap->{$source}->{$test}} => @$froms;
        }
    }

    if (my $smap = $data->{submap}) {
        for my $source (keys %$smap) {
            my $subs = $smap->{$source} || next;
            for my $sub (keys %$subs) {
                my $froms = $subs->{$sub} || next;
                # The sub being '*' *almost* always means the file was used/required
                # The other cases for this are similar magic, so lump them in
                if ($sub eq '*') {
                    push @{$loadmap->{$source}->{$test}} => @$froms;
                }
                else {
                    my $clean = $sub;
                    $clean =~ s/(?<!^)\b.*$//;
                    push @{$submap->{$source}->{$clean}->{$test}} => @$froms;
                }
            }
        }
    }
}


1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Log::CoverageAggregator - Module for aggregating coverage data
from a stream of events.

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
