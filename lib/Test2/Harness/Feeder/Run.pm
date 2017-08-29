package Test2::Harness::Feeder::Run;
use strict;
use warnings;

our $VERSION = '0.001001';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Feeder::Job;
use Test2::Harness::Run::Dir;
use Test2::Harness::Event;

BEGIN { require Test2::Harness::Feeder; our @ISA = ('Test2::Harness::Feeder') }

use Test2::Harness::Util::HashBase qw{
    -run
    -dir
    -runner
    -_active -job_lookup
    -_polled
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "The 'run' attribute is required"
        unless $self->{+RUN};

    my $dir = $self->{+DIR} or croak "'dir' is a required attribute";
    unless (blessed($dir) && $dir->isa('Test2::Harness::Run::Dir')) {
        croak "'dir' must be a valid directory" unless -d $dir;

        $dir = $self->{+DIR} = Test2::Harness::Run::Dir->new(
            root   => $dir,
            run_id => $self->{+RUN}->run_id,
        );
    }

    $self->{+_ACTIVE} = [];
}

sub _harness_event {
    my $self = shift;
    my ($job_id) = shift;

    my $run = $self->{+RUN};

    return Test2::Harness::Event->new(
        stream_id  => 'harness',
        job_id     => $job_id,
        event_id   => 'harness-' . ${$self->{+EVENT_COUNTER_REF}}++,
        run_id     => $run->run_id,
        stamp      => time,
        facet_data => {@_},
    );
}

sub poll {
    my $self = shift;
    my ($max) = @_;

    my $dir = $self->{+DIR};

    my $active = [];
    my @out;

    unless ($self->{+_POLLED}) {
        push @out => $self->_harness_event(0, harness_run => $self->{+RUN}, about => {no_display => 1});
        $self->{+_POLLED} = 1;
    }

    # Get any STDERR/STDOUT from the run itself
    push @out => map { $self->_harness_event(0, info => [{tag => 'INTERNAL', debug => 0, details => $_}]) } $dir->log_poll;
    push @out => map { $self->_harness_event(0, info => [{tag => 'INTERNAL', debug => 1, details => $_}]) } $dir->err_poll;

    my @new_jobs;
    for my $job ($dir->job_poll(1)) {
        my $job_id = $job->job_id;

        my $jfeed = Test2::Harness::Feeder::Job->new(
            job_id => $job_id,
            run_id => $self->{+RUN}->run_id,
            complete => $self->{+RUNNER} ? 0 : 1,
            dir => File::Spec->catdir($self->{+DIR}->root, $job_id),
            event_counter_ref => $self->{+EVENT_COUNTER_REF},
        );

        $self->{+JOB_LOOKUP}->{$job_id} = $jfeed;
        push @{$self->{+_ACTIVE}} => $jfeed;

        push @new_jobs => $self->_harness_event(
            $job_id,
            harness_job_launch => {stamp => time},
            harness_job        => $job,
        );
    }

    while (my $jfeed = shift @{$self->{+_ACTIVE}}) {
        my $nmax = $max - @new_jobs - @out;
        last if $nmax < 1;

        my @events;
        if(!eval { @events = $jfeed->poll($nmax); 1 }) {
            my $err = $@;
            push @events => $self->_harness_event(
                $jfeed->job_id,
                harness_job_end => {stamp => time},
                errors => [{ tag => 'JOB POLL', details => $err, fail => 1 }],
            );
        }
        elsif ($jfeed->complete && !@events) {
            # Get ALL remaining events, ignore max for now, lets close the job out.
            push @events => $jfeed->poll();

            push @events => $self->_harness_event(
                $jfeed->job_id,
                harness_job_end => {stamp => time},
            );
        }
        else {
            push @$active => $jfeed;
        }

        push @out => @events;
    }

    $self->{+_ACTIVE} = $active;

    return (@new_jobs, @out);
}

sub complete {
    my $self = shift;

    my $runner = $self->{+RUNNER} or return 1;
    my $exit = $runner->exit;

    # If runner exited with an error we need to be complete
    return 1 if $exit;

    return 0 if @{$self->{+_ACTIVE}};

    return $self->{+DIR}->complete;
}

sub job_completed {
    my $self = shift;
    my ($job_id) = @_;

    $self->{+JOB_LOOKUP}->{$job_id}->set_complete(1);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Feeder::Run - Get the event feed from a test run.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
