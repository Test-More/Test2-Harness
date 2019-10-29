package App::Yath::Command::replay;
use strict;
use warnings;

our $VERSION = '0.001100';

use App::Yath::Options;
require App::Yath::Command::test;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase qw/+renderers <final_data <log_file/;

include_options(
    'App::Yath::Options::Debug',
    'App::Yath::Options::Display',
    'App::Yath::Options::PreCommand',
);


sub group { 'log' }

sub summary { "Replay a test run from an event log" }

sub cli_args { "[--] event_log.jsonl[.gz|.bz2] [job1, job2, ...]" }

sub description {
    return <<"    EOT";
This yath command will re-run the harness against an event log produced by a
previous test run. The only required argument is the path to the log file,
which maybe compressed. Any extra arguments are assumed to be job id's. If you
list any jobs, only listed jobs will be processed.

This command accepts all the same renderer/formatter options that the 'test'
command accepts.
    EOT
}

sub run {
    my $self = shift;

    my $args      = $self->args;
    my $settings  = $self->settings;
    my $renderers = $self->App::Yath::Command::test::renderers;

    shift @$args if @$args && $args->[0] eq '--';

    $self->{+LOG_FILE} = shift @$args or die "You must specify a log file";
    die "'$self->{+LOG_FILE}' is not a valid log file" unless -f $self->{+LOG_FILE};
    die "'$self->{+LOG_FILE}' does not look like a log file" unless $self->{+LOG_FILE} =~ m/\.jsonl(\.(gz|bz2))?$/;

    my $jobs = @$args ? {map {$_ => 1} @$args} : undef;

    my $stream = Test2::Harness::Util::File::JSONL->new(name => $self->{+LOG_FILE});

    while (1) {
        my @events = $stream->poll(max => 1000) or last;

        for my $e (@events) {
            last unless defined $e;

            if (my $final = $e->{facet_data}->{harness_final}) {
                $self->{+FINAL_DATA} = $final;
            }
            else {
                next if $jobs && !$jobs->{$e->{job_id}};
                $_->render_event($e) for @$renderers;
            }
        }
    }

    $_->finish() for @$renderers;

    my $final_data = $self->{+FINAL_DATA} or die "Log did not contain final data!\n";

    $self->App::Yath::Command::test::render_final_data($final_data);

    return $final_data->{pass} ? 0 : 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command::replay - Command to replay test results from a log file.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
