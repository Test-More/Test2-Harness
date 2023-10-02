package Test2::Harness::Log::CoverageAggregator::ByRun;
use strict;
use warnings;

our $VERSION = '1.000155';

use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;

use parent 'Test2::Harness::Log::CoverageAggregator';
use Test2::Harness::Util::HashBase qw/<coverage <finalized/;

sub init_coverage {
    my $self = shift;
    return $self->{+COVERAGE} //= {aggregator => blessed($self)};
}

sub record_coverage {
    my $self = shift;
    my ($test, $data) = @_;

    my $coverage    = $self->{+COVERAGE}    // $self->init_coverage;
    my $files       = $coverage->{files}    //= {};
    my $alltestmeta = $coverage->{testmeta} //= {};
    my $testmeta    = $alltestmeta->{$test} //= {type => 'flat'};

    if (my $type = $data->{test_type}) {
        $testmeta->{type} = $type;
    }

    if (my $manager = $data->{from_manager}) {
        $testmeta->{manager} = $manager;
    }
}

sub touch {
    my $self   = shift;
    my %params = @_;

    my $file  = $params{source};
    my $sub   = $params{sub};
    my $test  = $params{test};
    my $mdata = $params{manager_data};

    my $coverage = $self->{+COVERAGE} // $self->init_coverage;
    my $files    = $coverage->{files} //= {};

    my $set = $files->{$file}->{$sub}->{$test} //= [];

    return unless $mdata;
    my $type = ref $mdata;

    if ($type eq 'ARRAY') {
        my %seen;
        @$set = grep { !$seen{$_}++ } @$set, @$mdata;
    }
    else {
        push @$set => $mdata;
    }
}

sub record_metrics {
    my $self = shift;
    my ($metrics) = @_;
    my $coverage = $self->{+COVERAGE} // $self->init_coverage;
    $coverage->{untested} = $metrics->{untested};
    $coverage->{metrics} = {files => $metrics->{files}, subs => $metrics->{subs}};
}

sub flush {
    my $self = shift;
    return unless $self->{+FINALIZED};
    return [ $self->{+COVERAGE} // $self->init_coverage ];
}

sub finalize {
    my $self = shift;
    $self->{+FINALIZED} = 1;
    $self->SUPER::finalize();
}

sub get_coverage_tests {
    my $class = shift;
    my ($settings, $changes, $coverage_data) = @_;

    my $filemap  = $coverage_data->{files}    // {};
    my $testmeta = $coverage_data->{testmeta} // {};

    my ($changes_exclude_loads, $changes_exclude_opens);
    if ($settings->check_prefix('finder')) {
        my $finder = $settings->finder;
        $changes_exclude_loads = $finder->changes_exclude_loads;
        $changes_exclude_opens = $finder->changes_exclude_opens;
    }

    my %tests;
    for my $file (keys %$changes) {
        my $parts_map  = $changes->{$file};
        my $parts_list = [keys %$parts_map];

        my $use_parts;
        if (!@$parts_list || $parts_map->{'*'}) {
            $use_parts = [keys %{$filemap->{$file}}];
        }
        else {
            $use_parts = $parts_list;
        }

        my %seen;
        for my $part (@$use_parts) {
            next if $seen{$part}++;
            my $ctests = $filemap->{$file}->{$part} or next;
            for my $test (keys %$ctests) {
                push @{$tests{$test}->{subs}} => @{$ctests->{$test}};
            }
        }

        unless ($changes_exclude_opens) {
            if (my $ltests = $filemap->{$file}->{'*'}) {
                for my $test (keys %$ltests) {
                    push @{$tests{$test}->{loads}} => @{$ltests->{$test}};
                }
            }
        }

        unless ($changes_exclude_loads) {
            if (my $otests = $filemap->{$file}->{'<>'}) {
                for my $test (keys %$otests) {
                    push @{$tests{$test}->{opens}} => @{$otests->{$test}};
                }
            }
        }
    }

    my @out;
    for my $test (sort keys %tests) {
        my $meta = $testmeta->{$test} // {type => 'flat'};
        my $type = $meta->{type};
        my $manager = $meta->{manager};

        # In these cases we have no choice but to run the entire file
        if ($type eq 'flat' || !$manager) {
            push @out => $test;
            next;
        }

        die "Invalid test type: $type" unless $type eq 'split';

        my $froms = $tests{$test} // [];
        my $ok = eval {
            require(mod2file($manager));
            my $specs = $manager->test_parameters($test, $froms, $changes, $coverage_data, $settings);

            $specs = { run => $specs } unless ref $specs;

            push @out => [$test, $specs]
                unless defined $specs->{run} && !$specs->{run};    # Intentional skip

            1;
        };
        my $err = $@;

        next if $ok;

        warn "Error processing coverage data for '$test' using manager '$manager'. Running entire test to be safe.\nError:\n====\n$@\n====\n";
        push @out => $test;
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Log::CoverageAggregator::ByRun - Aggregate test data by run

=head1 DESCRIPTION


=head1 SYNOPSIS


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
