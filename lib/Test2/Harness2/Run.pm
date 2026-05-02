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
    <resources
    <loggers
    <extend_loggers
    <test_loggers
    <extend_test_loggers
    <launch_job_timeout
    <requested_harness_uuid
    <hash_seed
};

# Default retry interval the harness will use when a launch_job
# request to a run service or preload stage times out waiting for
# its ack (see ARCHITECTURE.md / former IPC_AND_LOGGERS §14).
# Overridable per-run by setting launch_job_timeout at construction;
# a future CLI option will expose this to the user.
use constant DEFAULT_LAUNCH_JOB_TIMEOUT_SECS => 5;

sub init {
    my $self = shift;

    $self->{+RUN_ID}             //= gen_uuid();
    $self->{+JOBS}               //= [];
    $self->{+CREATED_AT}         //= time;
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
        $method   = 'rehydrate';
        @params   = ($input);
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

# Add a job to the spec at queue-build time. After the run has been
# handed to $harness->queue, the Spec is treated as immutable and
# this MUST NOT be called.
sub add_job {
    my ($self, $job) = @_;
    croak "'job' is required" unless defined $job;
    croak "'job' must be a Test2::Harness2::Run::Job"
        unless blessed($job) && $job->isa('Test2::Harness2::Run::Job');
    push @{$self->{+JOBS}} => $job;
    return;
}

sub TO_JSON { return {%{$_[0]}} }

sub rehydrate {
    my $class = shift;
    my ($hash) = @_;
    croak "rehydrate requires a hashref" unless ref($hash) eq 'HASH';

    my %args = %$hash;

    # Jobs round-trip: when reading back from disk each entry will be
    # a plain hash (TO_JSON unblessed it). Re-bless via Run::Job's
    # rehydrate-shaped constructor so callers see the same object
    # graph they would have seen pre-serialization. Already-blessed
    # entries are left alone.
    if (ref($args{jobs}) eq 'ARRAY') {
        my @rebuilt;
        for my $j (@{$args{jobs}}) {
            push @rebuilt => blessed($j) ? $j : Test2::Harness2::Run::Job->new(%$j);
        }
        $args{jobs} = \@rebuilt;
    }

    return $class->new(%args);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run - Immutable spec for a single test run.

=head1 SYNOPSIS

    use Test2::Harness2::Run;

    # Build from a list of test files
    my $run = Test2::Harness2::Run->from_files(files => ['t/foo.t', 't/bar.t']);

    # Hand to the harness; from this point the Run is treated as immutable.
    $harness->queue_test_run(run => $run);

=head1 DESCRIPTION

A C<Test2::Harness2::Run> represents the I<intent> to execute one logical
test run: an ordered collection of test jobs plus the policies (resources,
loggers, timeouts) the caller chose at queue time.

The Run itself does not track lifecycle state. Mutable state (pending /
running / done lists, per-job result hashes, exit summaries, etc.) lives
on a paired L<Test2::Harness2::Run::State> the run service constructs as
soon as the Run is accepted for execution.

Once the spec has been handed off to C<< $harness->queue >> it is treated
as immutable. Mutators are limited to the queue-build phase: C<add_job>
may be called to append a job, but no setter exists for the policy slots
because they are constructor-only.

=head1 ATTRIBUTES

=over 4

=item run_id

UUID identifying this run (auto-generated if not supplied).

=item jobs

Arrayref of L<Test2::Harness2::Run::Job> objects. Each job carries a
L<Test2::Harness2::Role::TestFile>-consuming value object.

=item created_at

Epoch timestamp (float) when the run was queued.

=item resources

Arrayref of L<Test2::Harness2::Role::Resource> instances scoped to this
specific run (as opposed to the harness-global resources on the harness
itself). Defaults to empty.

=item loggers / extend_loggers

Per-run service-logger overrides. Replace-style and extend-style; mutually
exclusive.

=item test_loggers / extend_test_loggers

Per-run test-job-logger overrides. Replace-style and extend-style;
mutually exclusive.

=item launch_job_timeout

Seconds the harness will wait for an ack on a launch_job IPC request
before retrying.

=item requested_harness_uuid

UUID of a specific harness the user wants this run to execute on, when
they pinned a target at queue time. C<undef> means "any available
harness". The runtime counterpart C<running_harness_uuid> on
L<Test2::Harness2::Run::State> records the harness that actually ran
the run.

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

=item $run = Test2::Harness2::Run->rehydrate(\%hash)

Reconstruct a Run from a hashref shaped like C<TO_JSON>'s output.
Re-blesses C<Run::Job> entries inside the C<jobs> arrayref.

=item $run->add_job($job)

Append a L<Test2::Harness2::Run::Job> to the spec at queue-build time.
Must not be called once the spec has been handed to the harness.

=item $list = $run->effective_service_loggers(\@harness_defaults)

=item $list = $run->effective_test_loggers(\@harness_defaults)

Apply replace / extend overrides against a list of harness-level
defaults and return a fresh arrayref.

=item $hash = $run->TO_JSON

Return a plain hash of every spec slot. Suitable for serialization to
the C<runs/E<lt>run_idE<gt>/spec.json> sidecar.

=back

=head1 SEE ALSO

L<Test2::Harness2::Run::State> -- mutable runtime state.

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
