package Test2::Harness::Log::CoverageAggregator::ByTest;
use strict;
use warnings;

our $VERSION = '1.000155';

use Scalar::Util qw/blessed/;
use Test2::Harness::Util qw/mod2file/;

use parent 'Test2::Harness::Log::CoverageAggregator';
use Test2::Harness::Util::HashBase qw/<in_progress <completed/;

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+IN_PROGRESS} //= {};
    $self->{+COMPLETED}   //= [];
}

sub start_test {
    my $self = shift;
    my ($test) = @_;

    $self->{+IN_PROGRESS}->{$test} //= {test => $test, files => {}, aggregator => blessed($self)};
}

sub stop_test {
    my $self = shift;
    my ($test) = @_;

    push @{$self->{+COMPLETED}} => delete $self->{+IN_PROGRESS}->{$test};
}

sub record_coverage {
    my $self = shift;
    my ($test, $data) = @_;

    if (my $manager = $data->{from_manager}) {
        $self->{+IN_PROGRESS}->{$test}->{manager} = $manager;
    }
}

sub touch {
    my $self   = shift;
    my %params = @_;

    my $file  = $params{source};
    my $sub   = $params{sub};
    my $test  = $params{test};
    my $mdata = $params{manager_data};

    my $set = $self->{+IN_PROGRESS}->{$test}->{files}->{$file}->{$sub} //= [];

    return unless $mdata;
    my $type = ref $mdata;

    if ($type eq 'ARRAY') {
        if (@$set) {
            my %seen;
            @$set = grep { !$seen{$_}++ } @$set, @$mdata;
        }
        else {
            push @$set => @$mdata;
        }
    }
    else {
        push @$set => $mdata;
    }
}

sub flush {
    my $self = shift;

    my $data = $self->{+COMPLETED} //= [];

    return unless @$data;

    $self->{+COMPLETED} = [];

    return $data;
}

sub finalize {
    my $self = shift;

    my $ip = $self->{+IN_PROGRESS};
    my $cm = $self->{+COMPLETED} //= [];

    push @{$cm} => {$_ => delete $ip->{$_}} for keys %$ip;

    $self->SUPER::finalize();
}

sub get_coverage_tests {
    my $class = shift;
    my ($settings, $changes, $coverage_data) = @_;

    my $test    = $coverage_data->{test}    // return;
    my $filemap = $coverage_data->{files}   // {};
    my $manager = $coverage_data->{manager} // undef;

    my ($changes_exclude_loads, $changes_exclude_opens);
    if ($settings->check_prefix('finder')) {
        my $finder = $settings->finder;
        $changes_exclude_loads = $finder->changes_exclude_loads;
        $changes_exclude_opens = $finder->changes_exclude_opens;
    }

    my %froms;
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
            my $cfroms = $filemap->{$file}->{$part} or next;
            push @{$froms{subs}} => @{$cfroms};
        }

        unless ($changes_exclude_loads) {
            if (my $lfroms = $filemap->{$file}->{'*'}) {
                push @{$froms{loads}} => @{$lfroms};
            }
        }

        unless ($changes_exclude_opens) {
            if (my $ofroms = $filemap->{$file}->{'<>'}) {
                push @{$froms{opens}} => @{$ofroms};
            }
        }
    }

    # Nothing to do for this test
    return unless keys %froms;

    # In these cases we have no choice but to run the entire file
    return ($test) unless $manager;

    my @out;
    my $ok = eval {
        require(mod2file($manager));
        my $specs = $manager->test_parameters($test, \%froms, $changes, $coverage_data, $settings);

        $specs = { run => $specs } unless ref $specs;

        push @out => [$test, $specs]
            unless defined $specs->{run} && !$specs->{run};    # Intentional skip

        1;
    };
    my $err = $@;

    return @out if $ok;

    warn "Error processing coverage data for '$test' using manager '$manager'. Running entire test to be safe.\nError:\n====\n$@\n====\n";
    return ($test);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Log::CoverageAggregator::ByTest - Aggregate coverage by test

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
