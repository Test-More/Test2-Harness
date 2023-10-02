package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '1.000155';

use Test2::Harness::Util::UUID qw/gen_uuid/;

use App::Yath::Tester qw/make_example_dir/;

use Importer Importer => qw/import/;
our @EXPORT_OK = qw/make_example_dir summarize_events/;

my $HARNESS_ID = 1;
sub summarize_events {
    my ($events) = @_;

    my @caller = caller(0);

    my $id     = $HARNESS_ID++;
    my $run_id = "run-$id";
    my $job_id = "job-$id";

    require Test2::Harness::Auditor::Watcher;
    my $watcher = Test2::Harness::Auditor::Watcher->new(job => 1, try => 0);

    require Test2::Harness::Event;
    for my $e (@$events) {
        my $fd = $e->facet_data;
        my $he = Test2::Harness::Event->new(
            facet_data => $fd,
            event_id   => gen_uuid(),
            run_id     => $run_id,
            job_id     => $job_id,
            stamp      => time,
            job_try    => 0,
        );

        $watcher->process($he);
    }

    return {
        plan       => $watcher->plan,
        pass       => $watcher->pass ? 1 : 0,
        fail       => $watcher->fail ? 1 : 0,
        errors     => $watcher->_errors,
        failures   => $watcher->_failures,
        assertions => $watcher->assertion_count,
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Tools::HarnessTester - Run events through a harness for a summary

=head1 DESCRIPTION

This tool allows you to process events through the L<Test2::Harness> auditor.
The main benefit here is to get a pass/fail result, as well as counts for
assertions, failures, and errors.

=head1 SYNOPSIS

    use Test2::V0;
    use Test2::API qw/intercept/;
    use Test2::Tools::HarnessTester qw/summarize_events/;

    my $events = intercept {
        ok(1, "pass");
        ok(2, "pass gain");
        done_testing;
    };

    is(
        summarize_events($events),
        {
            # Each of these is the negation of the other, no need to check both
            pass       => 1,
            fail       => 0,

            # The plan facet, see Test2::EventFacet::Plan
            plan       => {count => 2},

            # Statistics
            assertions => 2,
            errors     => 0,
            failures   => 0,
        }
    );

=head1 EXPORTS

=head2 $summary = summarize_events($events)

This takes an arrayref of events, such as that produced by C<intercept {...}>
from L<Test2::API>. The result is a hashref that summarizes the results of the
events as processed by L<Test2::Harness>, specifically the
L<Test2::Harness::Auditor::Watcher> module.

Fields in the summary hash:

=over 4

=item pass => $BOOL

=item fail => $BOOL

These are negatives of eachother. These represent the pass/fail state after
processing the events. When one is true the other should be false. These are
normalized to C<1> and C<0>.

=item plan => $HASHREF

If a plan was provided this will have the L<Test2::EventFacet::Plan> facet, but
as a hashref, not a blessed instance.

B<Note:> This is reference to the original data, not a copy, if you modify it
you will modify the event as well.

=item assertions => $INT

Count of assertions made.

=item errors => $INT

Count of errors seen.

=item failures => $INT

Count of failures seen.

=back

=head2 $path = make_example_dir()

This will create a temporary directory with 't', 't2', and 'xt' subdirectories
each of which will contain a single passing test.

This is re-exported from L<App::Yath::Tester>.

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
