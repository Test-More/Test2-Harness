package Test2::Harness2::Scheduler;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use List::Util qw/max/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    <con
    <runner_uuid
    <retry_limit
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Scheduler - In-memory scheduler: yields pending jobs and decides retries.

=head1 DESCRIPTION

C<Test2::Harness2::Scheduler> is a stateless helper that queries the harness
database to determine which job should run next and whether a finished try
should be retried. It holds no mutable state beyond its construction arguments;
all decisions are derived from the current database rows.

=head1 SYNOPSIS

    use Test2::Harness2::Scheduler;

    my $sched = Test2::Harness2::Scheduler->new(
        con         => $con,
        runner_uuid => $runner_uuid,
    );

    while (my $job = $sched->next_job) {
        my $try = $sched->start_try($job);
        # ... run the test ...
        $try->update({ passed => 1 });
        $sched->finish_try($job, $try);
    }

=head1 ATTRIBUTES

=over 4

=item con

Required. A L<DBIx::QuickORM::Connection> used to query the harness database.

=item runner_uuid

Required. UUID of the runner this scheduler is working on behalf of. Only jobs
belonging to this runner are considered.

=item retry_limit

Maximum number of retries allowed per job, beyond the initial try. Defaults to
C<0> (no retries: a job gets a single try unless this is raised). A retry only
happens when the prior try's C<should_retry> flag is set and the cap allows.
The first try has C<ord> 1; each retry increments C<ord>.

=back

=cut

sub init ($self) {
    croak "'con' is required"         unless $self->{+CON};
    croak "'runner_uuid' is required" unless $self->{+RUNNER_UUID};
    $self->{+RETRY_LIMIT} //= 0;
    return;
}

=pod

=head1 PUBLIC METHODS

=over 4

=item $job = $sched->next_job

Return the next job row that needs a try, or C<undef> if none remain. A job
is eligible when its C<passed> column is undefined (not yet resolved) and it
has no open (undecided) try.

=cut

sub next_job ($self) {
    my @jobs = $self->{+CON}->handle(
        'job',
        where => {
            runner_uuid => $self->{+RUNNER_UUID},
            passed      => undef,
        }
    )->all;

    for my $job (@jobs) {
        next if $self->_has_open_try($job);
        return $job;
    }

    return undef;
}

=pod

=item $try = $sched->start_try($job)

Insert a new try row for C<$job> with the next C<ord> value and a fresh UUID.
Returns the inserted try row.

=cut

sub start_try ($self, $job) {
    my $next_ord = ($self->_max_ord($job) // 0) + 1;
    return $self->{+CON}->handle('try')->insert({
        try_uuid => gen_uuid(),
        job_uuid => $job->field('job_uuid'),
        ord      => $next_ord,
    });
}

=pod

=item $sched->finish_try($job, $try)

Decide whether to retry or resolve the job after a try completes. If the try
has C<should_retry> set and the retry cap has not been reached, the job is left
unresolved so C<next_job> will issue another try. Otherwise the job's C<passed>
column is set: true if any try passed, false otherwise.

=cut

sub finish_try ($self, $job, $try) {
    return
        if $try->field('should_retry')
        && $self->_max_ord($job) < $self->{+RETRY_LIMIT} + 1;

    my $any_pass = 0;
    for my $t ($self->_tries($job)) {
        $any_pass = 1 if $t->field('passed');
    }
    $job->update({passed => $any_pass ? 1 : 0});
    return;
}

=pod

=item $bool = $sched->run_complete($run_uuid)

Return true when every job in the given run has been resolved (C<passed> is
defined). Returns false if the run has no jobs or any job is still pending.

=back

=cut

sub run_complete ($self, $run_uuid) {
    my @jobs = $self->{+CON}->handle('job', where => {run_uuid => $run_uuid})->all;
    return 0 unless @jobs;

    for my $job (@jobs) {
        return 0 unless defined $job->field('passed');
    }

    return 1;
}

=pod

=head1 PRIVATE METHODS

=over 4

=item @tries = $sched->_tries($job)

Return all try rows for the given job, in whatever order the database returns them.

=cut

sub _tries ($self, $job) {
    return $self->{+CON}->handle('try', where => {job_uuid => $job->field('job_uuid')})->all;
}

=pod

=item $ord = $sched->_max_ord($job)

Return the highest C<ord> value among the job's tries, or C<undef> if there are none.

=cut

sub _max_ord ($self, $job) {
    my @ords = map { $_->field('ord') } $self->_tries($job);
    return @ords ? max(@ords) : undef;
}

=pod

=item $bool = $sched->_has_open_try($job)

Return true if the job has at least one try whose C<passed> column is undefined
(the try has not yet finished).

=back

=cut

sub _has_open_try ($self, $job) {
    for my $t ($self->_tries($job)) {
        return 1 unless defined $t->field('passed');
    }
    return 0;
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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
