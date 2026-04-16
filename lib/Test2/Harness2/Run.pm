package Test2::Harness2::Run;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Run::Job;

use Object::HashBase qw{
    <run_id
    <jobs
    <created_at
    <pending
    <running
    <done
};

sub init {
    my $self = shift;

    $self->{+RUN_ID}     //= gen_uuid();
    $self->{+JOBS}       //= [];
    $self->{+CREATED_AT} //= time;
    $self->{+PENDING}    //= [map { $_->job_id } @{$self->{+JOBS}}];
    $self->{+RUNNING}    //= [];
    $self->{+DONE}       //= [];
}

sub from_files {
    my ($class, %params) = @_;

    my $files = $params{files} or croak "'files' is required";
    croak "'files' must be an arrayref" unless ref($files) eq 'ARRAY';

    my $run_id = $params{run_id} // gen_uuid();

    my @jobs = map {
        Test2::Harness2::Run::Job->new(
            test_file => $_,
            run_id    => $run_id,
        );
    } @$files;

    return $class->new(%params, run_id => $run_id, jobs => \@jobs);
}

sub mark_running {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+PENDING}};
    croak "job_id '$job_id' is not pending" if @new == @{$self->{+PENDING}};
    $self->{+PENDING} = \@new;
    push @{$self->{+RUNNING}} => $job_id;
}

sub mark_done {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+RUNNING}};
    croak "job_id '$job_id' is not running" if @new == @{$self->{+RUNNING}};
    $self->{+RUNNING} = \@new;
    push @{$self->{+DONE}} => $job_id;
}

sub is_complete {
    my $self = shift;
    return !@{$self->{+PENDING}} && !@{$self->{+RUNNING}};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run - A single test run (ordered list of jobs with FIFO state tracking)

=head1 SYNOPSIS

    use Test2::Harness2::Run;

    # Build from a list of test files
    my $run = Test2::Harness2::Run->from_files(files => ['t/foo.t', 't/bar.t']);

    # Advance job states
    my $job_id = $run->pending->[0];
    $run->mark_running($job_id);
    $run->mark_done($job_id);

    print "complete!\n" if $run->is_complete;

=head1 DESCRIPTION

A C<Test2::Harness2::Run> represents one logical test run: an ordered
collection of test jobs each of which moves through C<pending> →
C<running> → C<done> states.  The harness service maintains a queue of
these objects and advances their state as the collector completes each job.

=head1 ATTRIBUTES

=over 4

=item run_id

UUID identifying this run (auto-generated if not supplied).

=item jobs

Arrayref of L<Test2::Harness2::Run::Job> objects.

=item created_at

Epoch timestamp (float) when the run was created.

=item pending

Arrayref of job_ids not yet started.

=item running

Arrayref of job_ids currently being executed.

=item done

Arrayref of job_ids that have finished.

=back

=head1 METHODS

=over 4

=item $run = Test2::Harness2::Run->from_files(files => \@files, %opts)

Construct a run from a list of test file paths.  Each file becomes one
L<Test2::Harness2::Run::Job>.

=item $run->mark_running($job_id)

Move C<$job_id> from C<pending> to C<running>.  Croaks if the job is not
currently pending.

=item $run->mark_done($job_id)

Move C<$job_id> from C<running> to C<done>.  Croaks if the job is not
currently running.

=item $bool = $run->is_complete

Returns true when both C<pending> and C<running> are empty.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
