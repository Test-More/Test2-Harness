package Test2::Harness::Log::CoverageAggregator;
use strict;
use warnings;

our $VERSION = '1.000155';

use File::Find qw/find/;
use Test2::Harness::Util::HashBase qw/<touched <job_map +can_touch +can_start_test +can_stop_test +can_record_coverage <file +io <encode/;

sub init {
    my $self = shift;
    $self->{+TOUCHED} //= {};
    $self->{+JOB_MAP} //= {};

    $self->{+CAN_TOUCH}           = !!$self->can('touch');
    $self->{+CAN_START_TEST}      = !!$self->can('start_test');
    $self->{+CAN_STOP_TEST}       = !!$self->can('stop_test');
    $self->{+CAN_RECORD_COVERAGE} = !!$self->can('record_coverage');

    if (my $file = $self->{+FILE}) {
        open(my $fh, '>', $file) or die "Could not open file '$file' for writing: $!";
        $self->{+IO} = $fh;
    }
}

sub flush    { }
sub finalize { $_[0]->write }
sub record_metrics { }

sub write {
    my $self = shift;

    my $list = $self->flush() or return;
    my $io = $self->{+IO} or return $list;

    my $encode = $self->{+ENCODE};
    for my $item (@$list) {
        my $encoded = $encode ? $encode->($item) : $item;
        print $io $encoded;
    }

    return $list;
}

sub process_event {
    my $self = shift;
    my ($e) = @_;

    return unless $e;
    return unless keys %$e;

    my $job_map = $self->{+JOB_MAP} //= {};
    my $job_id  = $e->{job_id} // 0;

    my $test = $job_map->{$job_id};

    if (my $start = $e->{facet_data}->{harness_job_start}) {
        $test //= $start->{rel_file};

        $self->start_test($test, $e) if $self->{+CAN_START_TEST};
    }

    if (my $end = $e->{facet_data}->{harness_job_end}) {
        $test //= $end->{rel_file};

        $self->stop_test($test, $e) if $self->{+CAN_STOP_TEST};
    }

    $job_map->{$job_id} //= $test if $test;

    if (my $c = $e->{facet_data}->{coverage}) {
        die "Got coverage data before test start! (Weird event order?)" unless $test;
        $self->_touch_coverage($test, $c, $e);
        $self->record_coverage($test, $c, $e) if $self->{+CAN_RECORD_COVERAGE};
    }

    return $self->write();
}

sub _touch_coverage {
    my $self = shift;
    my ($test, $data, $e) = @_;

    if (my $new = $data->{files}) {
        for my $file (keys %$new) {
            my $ndata = $new->{$file} // next;
            for my $sub (keys %$ndata) {
                $self->{+TOUCHED}->{$file}->{$sub}++;

                next unless $self->{+CAN_TOUCH};
                $self->touch(source => $file, sub => $sub, test => $test, manager_data => $ndata->{$sub}, event => $e);
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
    my $touched  = $self->{+TOUCHED} //= {};

    my $metrics = {
        files    => {total => 0,  tested => 0},
        subs     => {total => 0,  tested => 0},
        untested => {files => [], subs   => {}},
    };

    my $untested = $metrics->{untested};

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
                my $cfile = $touched->{$file};

                if ($cfile) {
                    $metrics->{files}->{tested}++
                }
                else {
                    push @{$untested->{files}} => $file;
                }

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
            $untested->{subs}->{$file} = [sort @val];
        }
    }

    my %seen;
    @{$untested->{files}} = sort grep { !$seen{$_}++ } @{$untested->{files}};

    $self->record_metrics($metrics);

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

    # Get a structure like { source_file => { source_method => $touched_count, ... }, ...}
    my $touched_source = $agg->touched;

    # Get a structure like
    # {
    #     files => {total => 5,  tested => 2},
    #     subs  => {total => 20, tested => 12},
    #     untested => {files => \@file_list, subs => {file => \@sub_list, ...}},
    # }
    my $metrics = $agg->metrics;


=head1 METHODS

=head2 IMPLEMENTABLE IN SUBLCASSES

If you implement these in a subclass they will be called for you at the proper
times, making subclassing much easier. In most cases you can avoid overriding
process_event().

=over 4

=item $agg->start_test($test, $event)

This is called once per test when it starts.

B<Note:> If a test is run more than once (re-run) it will start and stop again
for each re-run. The event is also provided as an argument so that you can
check for a try-id or similar in the event that re-runs matter to you.

=item $agg->stop_test($test, $event)

This is called once per test when it stops.

B<Note:> If a test is run more than once (re-run) it will start and stop again
for each re-run. The event is also provided as an argument so that you can
check for a try-id or similar in the event that re-runs matter to you.

=item $agg->record_coverage($test, $coverage_data, $event)

This is called once per coverage event (there can be several in a test,
specially if it forks or uses threads).

In most cases you probably want to leave this unimplemented and implement the
C<touch()> method instead of iterating over the coverage structure yourself.

=item $agg->touch(source => $file, sub => $sub, test => $test, manager_data => $mdata, event => $event)

Every touch applied to a source file (and sub) will trigger this method call.

=over 4

=item source => $file

The source file that was touched

=item sub => $sub

The source subroutine that was touched. B<Note:> This may be '<>' if the source
file was opened via C<open()> or '*' if code outside of a subroutine was
executed by the test.

=item test => $test

The test file that did the touching.

=item manager_data => $mdata

If the test file makes use of a source manager to attach extra data to
coverage, this is where that data will be. A good example would be test suites
that use tools similar to Test::Class or Test::Class::Moose where all tests are
run in methods and you want to track what test method does the touching. Please
note that this level of coverage tracking is not automatic.

=item event => $event

The full event being processed.

=back

=back

=head2 PUBLIC API

=over 4

=item $agg->process_event($event)

Process the event, aggregating any coverage info it may contain.

=item $touched = $add->touched()

Returns the following structure, which tells you how many times a specific
source file's subroutines were called. There are also "special" subroutines
'<>' and '*' which mean "file was opened via open" and "code outside of a
subroutine".

    {
        source_file => {
            source_method => $touched_count,
            ...
        },
        ...
    }

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

        untested => {
            files => \@file_list,
            subs => {
                file => \@sub_list,
                ...
            }
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
