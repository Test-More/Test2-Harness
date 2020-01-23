package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '1.000000';

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
    my $watcher = Test2::Harness::Auditor::Watcher->new(job => 1, live => 0, try => 0);

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
        pass       => $watcher->pass,
        fail       => $watcher->fail,
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
