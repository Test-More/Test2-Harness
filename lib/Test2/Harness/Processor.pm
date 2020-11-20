package Test2::Harness::Processor;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak/;

use Test2::Harness::Collector;
use Test2::Harness::Auditor;

use Test2::Harness::Util::HashBase qw{
    <run
    <job
    <workdir
    <run_id

    <settings

    <action

    <runner_pid

    <collector <auditor
};

sub init {
    my $self = shift;

    croak "'run' is required" unless $self->{+RUN};
    croak "'job' is required" unless $self->{+JOB};

    $self->{+AUDITOR} = Test2::Harness::Auditor->new(
        run_id => $self->{+RUN_ID},
        action => $self->{+ACTION},
    );

    $self->{+COLLECTOR} = Test2::Harness::Collector->new(
        settings   => $self->{+SETTINGS},
        workdir    => $self->{+WORKDIR},
        run_id     => $self->{+RUN_ID},
        runner_pid => $self->{+RUNNER_PID},
        run        => $self->{+RUN},
        action     => sub { $self->{+AUDITOR}->process_event($_[0]) },
        jobs_done  => 1,
    );

}

sub process {
    my $self = shift;

    my $job = $self->{+JOB};
    my $job_id = $job->{job_id} or die "No job id!";

    $self->{+COLLECTOR}->process_tasks(only_job_id => $job_id);
    $self->{+COLLECTOR}->add_job($self->{+JOB});
    $self->{+COLLECTOR}->process(keep_run_dir => 1);
    $self->{+AUDITOR}->finish();
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Processor - Module that connects a single collector to a single
auditor

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
