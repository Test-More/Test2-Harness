package Test2::Harness::Log::CoverageAggregator;
use strict;
use warnings;

our $VERSION = '1.000065';

use File::Find qw/find/;
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
    my $files       = $coverage->{files}    //= {};
    my $alltestmeta = $coverage->{testmeta} //= {};
    my $testmeta    = $alltestmeta->{$test} //= {};

    if (my $type = $data->{test_type}) {
        $testmeta->{type} = $type;
    }

    if (my $manager = $data->{from_manager}) {
        $testmeta->{manager} = $manager;
    }

    if (my $new = $data->{files}) {
        for my $file (keys %$new) {
            my $ndata = $new->{$file} // next;
            my $fdata = $files->{$file} //= {};

            for my $sub (keys %$ndata) {
                my $nsub = $ndata->{$sub} // next;
                my $fsub = $fdata->{$sub} //= {};
                if ($fsub->{$test}) {
                    $fsub->{$test} = [@{$fsub->{$test}}, @$nsub];
                }
                else {
                    $fsub->{$test} = $nsub;
                }
            }
        }
    }
}

my %PERL_TYPES = (
    pl  => 1,
    pm  => 1,
    t   => 1,
    tx  => 1,
    t2  => 1,
    pmc => 1,
);

sub build_metrics {
    my $self = shift;
    my %params = @_;

    my $private = $params{exclude_private};

    my $dirs     = $params{dirs}  // ['lib'];
    my $types    = $params{types} // ['pm', 'pl'];
    my $coverage = $self->{+COVERAGE} //= {};
    my $untested = $coverage->{untested} = {files => [], subs => {}};

    my $metrics  = $coverage->{metrics}  = {
        files => {total => 0, tested => 0},
        subs  => {total => 0, tested => 0},
    };

    my %type_check = map { m/\.?([^\.]+)$/g; (lc($1) => 1) } @$types;

    my $raw_untested = {};
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $type = lc($_);
                $type =~ s/^.*\.([^\.]+)$/$1/;
                return unless $type_check{$type};
                $metrics->{files}->{total}++;

                my $file  = $File::Find::name;
                my $cfile = $coverage->{files}->{$file};

                $metrics->{files}->{tested}++ if $cfile;

                for my $sub ($PERL_TYPES{$type} ? $self->scan_subs($file) : ('<>')) {
                    next if $sub =~ m/^_/ && $private;

                    my $special_sub = $sub !~ m/^\w/;

                    $metrics->{subs}->{total}++ unless $special_sub;

                    if ($cfile && $cfile->{$sub}) {
                        $metrics->{subs}->{tested}++ unless $special_sub;
                    }
                    else {
                        $raw_untested->{$file}->{$sub} = 1;
                    }
                }
            },
        },
        @$dirs
    );

    for my $file (keys %$raw_untested) {
        my @val = keys %{$raw_untested->{$file}};
        next unless @val;

        if (@val == 1 && $val[0] eq '<>') {
            push @{$untested->{files}} => $file;
        }
        else {
            $untested->{subs}->{$file} = \@val;
        }
    }

    return $metrics;
}

sub scan_subs {
    my $self = shift;
    my ($file) = @_;

    my @subs;

    my $fh;
    unless (open($fh, '<', $file)) {
        warn "Could not open file '$file': $!";
        return;
    }

    my $in_pod = 0;
    while (my $line = <$fh>) {
        $in_pod = 1 if $line =~ m/^=\w/;

        if ($in_pod) {
            next unless $line =~ m/^=cut/i;
            $in_pod = 0;
            next;
        }

        last if $line =~ m/^__(END|DATA)__$/;

        next unless $line =~ m/^\s*sub\s+(\w+)/;
        push @subs => $1;
    }

    return @subs;
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

=item $metrics = $agg->build_metrics()

=item $metrics = $agg->build_metrics(exclude_private => $BOOL)

Will build metrics, and include them in the output from C<< $agg->coverage() >>
next time it is called.

The C<exclude_private> option, when set to true, will exclude any method that
beings with an underscore from the coverage metrics and untested sub list.

Metrics:

    {
        files => {total => 20, tested => 18},
        subs  => {total => 80, tested => 70},
    }

=item $hashref = $agg->coverage()

Produce a hashref of all aggregated coverage data:

    {
        files => {
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
        },
        testmeta => {
            'test_file_a.t' => {...},
        },

        # If you called ->build_metrics this will also be present
        metrics => {
            files => {total => 20, tested => 18},
            subs  => {total => 80, tested => 70},
        },

        # If you called ->build_metrics this will also be present
        untested => {
            files => ['lib/untested.pm', ...],
            subs => {
                'lib/untested.pm' => [ 'foo', 'bar', ... ],
                ...,
            },
        },
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
