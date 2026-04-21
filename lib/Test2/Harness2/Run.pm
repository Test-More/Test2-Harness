package Test2::Harness2::Run;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Role::Tiny ();

use Test2::Harness2::Run::Job;
use Test2::Harness2::Role::TestFile;
use Test2::Harness2::Util qw/load_module/;

use Object::HashBase qw{
    <run_id
    <jobs
    <created_at
    <pending
    <running
    <done
    <resources
    <aborted_reason
    <loggers
    <extend_loggers
    <test_loggers
    <extend_test_loggers
    <launch_job_timeout
    +resources_started
    +resources_torn_down
};

# Default retry interval the harness will use when a launch_job
# request to a run service or preload stage times out waiting for
# its ack (see IPC_AND_LOGGERS §14). Overridable per-run by setting
# launch_job_timeout at construction; a future CLI option will
# expose this to the user.
use constant DEFAULT_LAUNCH_JOB_TIMEOUT_SECS => 5;

sub init {
    my $self = shift;

    $self->{+RUN_ID}             //= gen_uuid();
    $self->{+JOBS}               //= [];
    $self->{+CREATED_AT}         //= time;
    $self->{+PENDING}            //= [map { $_->job_id } @{$self->{+JOBS}}];
    $self->{+RUNNING}            //= [];
    $self->{+DONE}               //= [];
    $self->{+RESOURCES}          //= [];
    $self->{+LAUNCH_JOB_TIMEOUT} //= DEFAULT_LAUNCH_JOB_TIMEOUT_SECS;

    # Per-run logger overrides. Each of the four slots is an arrayref
    # of logger specs; each pair is mutually exclusive.
    #
    #   loggers               Replace the harness's service_loggers for
    #                         this run's RunService + resource services.
    #   extend_loggers        Append to the harness's service_loggers
    #                         for this run.
    #   test_loggers          Replace the harness's test_loggers for
    #                         test jobs in this run.
    #   extend_test_loggers   Append to the harness's test_loggers for
    #                         this run's test jobs.
    #
    # The effective list is computed at launch time by the harness /
    # run service; the Run only carries intent.
    for my $slot (LOGGERS, EXTEND_LOGGERS, TEST_LOGGERS, EXTEND_TEST_LOGGERS) {
        next unless defined $self->{$slot};
        croak "'$slot' must be an arrayref"
            unless ref($self->{$slot}) eq 'ARRAY';
    }

    croak "'loggers' and 'extend_loggers' are mutually exclusive"
        if defined $self->{+LOGGERS} && defined $self->{+EXTEND_LOGGERS};

    croak "'test_loggers' and 'extend_test_loggers' are mutually exclusive"
        if defined $self->{+TEST_LOGGERS} && defined $self->{+EXTEND_TEST_LOGGERS};
}

# Effective per-run logger lists. Given the harness-level defaults,
# return the list the run should actually use for its service /
# test-job collectors. Replace-style overrides win outright; extend-
# style overrides append to the harness defaults. Each returns a
# fresh arrayref so callers can mutate without reaching back into
# the Run.
sub effective_service_loggers {
    my ($self, $harness_defaults) = @_;
    return $self->_effective($self->{+LOGGERS}, $self->{+EXTEND_LOGGERS}, $harness_defaults);
}

sub effective_test_loggers {
    my ($self, $harness_defaults) = @_;
    return $self->_effective($self->{+TEST_LOGGERS}, $self->{+EXTEND_TEST_LOGGERS}, $harness_defaults);
}

sub _effective {
    my ($self, $replace, $extend, $defaults) = @_;
    $defaults //= [];
    return [@$replace]            if defined $replace;
    return [@$defaults, @$extend] if defined $extend;
    return [@$defaults];
}

sub from_files {
    my ($class, %params) = @_;

    my $files = delete $params{files} or croak "'files' is required";
    croak "'files' must be an arrayref" unless ref($files) eq 'ARRAY';

    my $run_id = $params{run_id} // gen_uuid();

    # Accept a role-consuming blessed object, a [$class, @ctor_args]
    # arrayref (passed through as $class->new(@ctor_args)), or a
    # TO_JSON-shaped hashref carrying '__test_file_class__' (the
    # class is asked to rehydrate itself from the hash). There is no
    # caller-side default class.
    my @jobs;
    for my $input (@$files) {
        my $test_file = $class->_coerce_test_file($input);
        push @jobs => Test2::Harness2::Run::Job->new(
            test_file => $test_file,
            run_id    => $run_id,
        );
    }

    return $class->new(%params, run_id => $run_id, jobs => \@jobs);
}

sub _coerce_test_file {
    my $class = shift;
    my ($input) = @_;

    if (blessed($input)) {
        return $input
            if Role::Tiny::does_role($input, 'Test2::Harness2::Role::TestFile');
        croak "files entries must consume Test2::Harness2::Role::TestFile, got a " . ref($input);
    }

    my $ref = ref($input);

    my ($tf_class, $method, @params);
    if ($ref eq 'ARRAY') {
        $method = 'new';
        ($tf_class, @params) = @$ref;
    }
    elsif ($ref eq 'HASH') {
        $method = 'rehydrate';
        @params = ($input);
        $tf_class = $input->{__test_file_class__}
            or croak "hashref entries must carry '__test_file_class__' (got keys: " . join(',', sort keys %$input) . ")";
    }

    croak "files entries must consume Test2::Harness2::Role::TestFile or be a construction arrayref with a class and parameters, or a hashref with __test_file_class__"
        unless $tf_class && $method;

    my $ok  = eval { load_module($tf_class); 1 };
    my $err = $@;
    croak "could not load '$tf_class': $err" unless $ok;

    croak "'$tf_class' does not consume Test2::Harness2::Role::TestFile"
        unless Role::Tiny::does_role($tf_class, 'Test2::Harness2::Role::TestFile');

    return $tf_class->$method(@params);
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

sub mark_skipped {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+PENDING}};
    croak "job_id '$job_id' is not pending" if @new == @{$self->{+PENDING}};
    $self->{+PENDING} = \@new;
    push @{$self->{+DONE}} => $job_id;
}

sub is_complete {
    my $self = shift;
    return !@{$self->{+PENDING}} && !@{$self->{+RUNNING}};
}

sub TO_JSON { return {%{$_[0]}} }

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

Arrayref of L<Test2::Harness2::Run::Job> objects. Each job carries a
L<Test2::Harness2::Role::TestFile>-consuming value object.

=item created_at

Epoch timestamp (float) when the run was created.

=item pending

Arrayref of job_ids not yet started.

=item running

Arrayref of job_ids currently being executed.

=item done

Arrayref of job_ids that have finished.

=item resources

Arrayref of L<Test2::Harness2::Role::Resource> instances that are scoped
to this specific run (as opposed to the harness-global resources on the
harness itself). Defaults to empty. The harness service starts per-run
resource services lazily when the run is first considered for launch,
and tears them down when the run completes.

=back

=head1 METHODS

=over 4

=item $run = Test2::Harness2::Run->from_files(files => \@files, %opts)

Construct a run from a list of C<files>. Each entry becomes one
L<Test2::Harness2::Run::Job>. Entries may be:

=over 4

=item * an object consuming L<Test2::Harness2::Role::TestFile>

=item * an arrayref C<[$class, @ctor_args]>. The class is loaded if
needed and constructed via C<< $class->new(@ctor_args) >>.

=item * a hashref carrying a C<__test_file_class__> key naming the
concrete TestFile class (as emitted by
L<Test2::Harness2::Role::TestFile/TO_JSON>). The class is loaded if
needed and asked to L<< rehydrate|Test2::Harness2::Role::TestFile/rehydrate >>
itself from the hashref.

=back

Bare path strings are B<not> accepted: callers must hand in one of
the three forms above.

=item $run->mark_running($job_id)

Move C<$job_id> from C<pending> to C<running>.  Croaks if the job is not
currently pending.

=item $run->mark_done($job_id)

Move C<$job_id> from C<running> to C<done>.  Croaks if the job is not
currently running.

=item $run->mark_skipped($job_id)

Move C<$job_id> directly from C<pending> to C<done> without going through
C<running>.  Used by the scheduler when a resource rules a job
permanently-unsatisfiable.  Croaks if the job is not currently pending.

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
