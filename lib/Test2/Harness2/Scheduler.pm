package Test2::Harness2::Scheduler;
use v5.38;

our $VERSION = '2.000000';

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

use Object::HashBase qw{
    <runs
    <run_ord_counter
    <max_concurrent
    <no_more
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Scheduler - Decide when to start runs and jobs.

=head1 DESCRIPTION

Tracks queued runs and their jobs and decides what to launch next. The initial
version runs a single run and a single job at a time; resources, custom
launchers, and retries come later.

Each queued run is a L<Test2::Harness2::Run> owning one
L<Test2::Harness2::Run::Job> per test file.

=head1 ATTRIBUTES

=over 4

=item runs

Arrayref of queued L<Test2::Harness2::Run> objects, in queue order.

=item max_concurrent

How many jobs may run at once. Defaults to 1.

=item no_more_runs

Set once the caller has declared no further runs will be queued; the scheduler
is L</all_done> when this is set and every job has finished.

=back

=cut

sub init ($self) {
    $self->{+RUNS}            //= [];
    $self->{+RUN_ORD_COUNTER} //= 1;
    $self->{+MAX_CONCURRENT}  //= 1;
    $self->{+NO_MORE}         //= 0;
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $run = $self->queue_run(files => \@files, run_uuid => ..., job_uuids => [...])

=item $run = $self->queue_run(jobs => \@specs, run_uuid => ...)

Queue a run. Assigns the next C<run_ord> and vivifies a C<run_uuid> when not
supplied. Returns the L<Test2::Harness2::Run> object.

Two job sources are accepted. The simple C<files> form builds one bare
L<Test2::Harness2::Run::Job> per path (numbered from 1, C<job_uuid> vivified).
The C<jobs> form takes a list of already-scanned job specs (the hashes a
producer gets from L<Test2::Harness2::Run::Job/TO_JSON>) and rehydrates each
into a Run::Job; the run-side identity (C<run_uuid> / C<run_ord>) is always
reassigned authoritatively here, while a spec's C<job_uuid> / C<job_ord> are
honored when present and vivified otherwise. When both are given C<jobs> wins.

=item $job = $self->next_job

The next pending L<Test2::Harness2::Run::Job> to launch, or C<undef> when nothing
should launch right now -- either the concurrency cap is reached or no job is
pending.

=item $self->mark_running($job) / $self->mark_done($job)

Move a job between C<pending> / C<running> / C<done>.

=item $self->no_more_runs

Declare that no further runs will be queued.

=item all_done

=item $bool = $self->all_done

True when L</no_more_runs> is set and every queued job has finished.

=back

=cut

sub queue_run ($self, %args) {
    my $run = Test2::Harness2::Run->new(
        run_uuid => $args{run_uuid} // gen_uuid(),
        run_ord  => $self->{+RUN_ORD_COUNTER}++,
    );

    if (my $specs = $args{jobs}) {
        $self->_add_spec_jobs($run, $specs);
    }
    else {
        $self->_add_file_jobs($run, $args{files} || [], $args{job_uuids} || []);
    }

    push @{$self->{+RUNS}} => $run;
    return $run;
}

sub no_more_runs ($self) {
    $self->{+NO_MORE} = 1;
    return;
}

sub next_job ($self) {
    return undef if $self->_running_count >= $self->{+MAX_CONCURRENT};

    for my $run (@{$self->{+RUNS}}) {
        for my $job (@{$run->jobs}) {
            next unless $job->state eq 'pending';
            return $job;
        }
    }

    return undef;
}

sub mark_running ($self, $job) { return $self->_set_state($job, 'running') }
sub mark_done    ($self, $job) { return $self->_set_state($job, 'done') }

sub all_done ($self) {
    return 0 unless $self->{+NO_MORE};

    for my $run (@{$self->{+RUNS}}) {
        for my $job (@{$run->jobs}) {
            return 0 unless $job->state eq 'done';
        }
    }

    return 1;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $n = $self->_running_count

How many jobs are currently in the C<running> state.

=item $self->_set_state($job, $state)

Set a job's C<state>.

=item $self->_add_file_jobs($run, \@files, \@job_uuids)

Build one bare Run::Job per file path and add it to C<$run>.

=item $self->_add_spec_jobs($run, \@specs)

Rehydrate each producer job spec into a Run::Job under C<$run>, reassigning the
authoritative run identity and resetting lifecycle state to a fresh
C<pending> / try 1.

=back

=cut

sub _add_file_jobs ($self, $run, $files, $job_uuids) {
    my $ord = 1;
    for my $file (@$files) {
        $run->add_job(Test2::Harness2::Run::Job->new(
            run_uuid => $run->run_uuid,
            run_ord  => $run->run_ord,
            job_uuid => $job_uuids->[$ord - 1] // gen_uuid(),
            job_ord  => $ord,
            file     => $file,
        ));
        $ord++;
    }
    return;
}

sub _add_spec_jobs ($self, $run, $specs) {
    my $ord = 1;
    for my $spec (@$specs) {
        $run->add_job(Test2::Harness2::Run::Job->new(
            %$spec,
            run_uuid => $run->run_uuid,
            run_ord  => $run->run_ord,
            job_uuid => $spec->{job_uuid} // gen_uuid(),
            job_ord  => $spec->{job_ord}  // $ord,
            try      => 1,
            state    => 'pending',
        ));
        $ord++;
    }
    return;
}

sub _set_state ($self, $job, $state) {
    $job->set_state($state);
    return;
}

sub _running_count ($self) {
    my $n = 0;
    for my $run (@{$self->{+RUNS}}) {
        $n++ for grep { $_->state eq 'running' } @{$run->jobs};
    }
    return $n;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
