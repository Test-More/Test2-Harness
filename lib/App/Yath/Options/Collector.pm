package App::Yath::Options::Collector;
use strict;
use warnings;

our $VERSION = '1.000125';

use App::Yath::Options;

option_group {prefix => 'collector', category => "Collector Options"} => sub {
    option max_open_jobs => (
        type => 's',
        description => 'Maximum number of jobs a collector can process at a time, if more jobs are pending their output will be delayed until the earlier jobs have been processed. (Default: double the -j value)',
        long_examples  => [' 18'],
        short_examples => [' 18'],
    );

    option max_poll_events => (
        type => 's',
        description => 'Maximum number of events to poll from a job before jumping to the next job. (Default: 1000)',
        default => 1000,
        long_examples  => [' 1000'],
        short_examples => [' 1000'],
    );

    post \&collector_post;
};

sub collector_post {
    my %params   = @_;
    my $settings = $params{settings};

    unless ($settings->collector->max_open_jobs) {
        my $j = $settings->runner->job_count;
        my $max_open = 2 * $j;
        $settings->collector->field(max_open_jobs => $max_open);
    }
}


1;

__END__


=pod

=encoding UTF-8

=head1 NAME

App::Yath::Options::Collector - collector options for Yath.

=head1 DESCRIPTION

This is where the command line options for the collector are defined.

=head1 PROVIDED OPTIONS POD IS AUTO-GENERATED

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
