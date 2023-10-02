package Test2::Harness::Runner::Resource;
use strict;
use warnings;

use Term::Table;
use Time::HiRes qw/time/;
use Test2::Util::Times qw/render_duration/;

our $VERSION = '1.000155';

sub scope_global { 0 }
sub scope_host   { 0 }
sub scope_run    { 1 }

sub setup {}

sub new {
    my $class = shift;
    return bless({@_}, $class);
}

sub tick { }

sub refresh { }

sub discharge { }

sub sort_weight {
    my $class = shift;
    return 100 if $class->job_limiter;
    return 50;
}

sub job_limiter { 0 }

sub job_limiter_max { }

sub job_limiter_at_max { 0 }

sub available { -1 }

sub record { }

sub assign { }

sub release { }

sub cleanup { }

sub status_data {()}

sub status_lines {
    my $self = shift;

    my $data = $self->status_data || return;
    return unless @$data;

    my $out = "";

    for my $group (@$data) {
        my $gout = "\n";
        $gout .= "**** $group->{title} ****\n\n" if defined $group->{title};

        for my $table (@{$group->{tables} || []}) {
            my $rows = $table->{rows};

            if (my $format = $table->{format}) {
                my $rows2 = [];

                for my $row (@$rows) {
                    my $row2 = [];
                    for (my $i = 0; $i < @$row; $i++) {
                        my $val = $row->[$i];
                        my $fmt = $format->[$i];

                        $val = defined($val) ? render_duration($val) : '--'
                            if $fmt && $fmt eq 'duration';

                        push @$row2 => $val;
                    }
                    push @$rows2 => $row2;
                }

                $rows = $rows2;
            }

            next unless $rows && @$rows;

            my $tt = Term::Table->new(
                header => $table->{header},
                rows   => $rows,

                sanitize     => 1,
                collapse     => 1,
                auto_columns => 1,

                %{$table->{term_table_opts} || {}},
            );

            $gout .= "** $table->{title} **\n" if defined $table->{title};
            $gout .= "$_\n" for $tt->render;
            $gout .= "\n";
        }

        if ($group->{lines} && @{$group->{lines}}) {
            $gout .= "$_\n" for @{$group->{lines}};
            $gout .= "\n";
        }

        $out .= $gout;
    }

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource - Base class for resource management classes

=head1 DESCRIPTION

Sometimes you have limited resources that must be shared/divided between tests
that run concurrently. Resource classes give you a way to leverage the IPC
system used by L<Test2::Harness> to manage resource assignment and recovery.

=head1 SYNOPSIS

Here is a resource class that simply assigns an integer to each test. It would
be possible to re-use integers, but since there are infinite integers this
example is kept simple and just always grabs the next one.

    package Test2::Harness::Runner::Resource::Foo;
    use strict;
    use warnings;

    use parent 'Test2::Harness::Runner::Resource';

    sub setup {
        my $class = shift; # NOT AN INSTANCE
        ...
    }

    sub available {
        my $self = shift;
        my ($task) = @_;

        # There are an infinite amount of integers, so we always return true
        return 1;
    }

    sub assign {
        my $self = shift;
        my ($task, $state) = @_;

        # Next ID, do not record the state change yet!
        my $id = 1 + ($self->{ID} //= 0);

        print "ASSIGN: $id = $task->{job_id}\n";

        # 'record' should get whatever we need to record the resource, whatever you
        # pass in will become the argument to the record() sub below. This may be a
        # scalar, a hash, an array, etc. It will be serialized to JSON before
        # record() sees it.
        $state->{record} = $id;

        # Pass the resource into the test, this can be done as envronment variables
        # and/or arguments to the test (@ARGV).
        $state->{env_vars}->{FOO_ID} = $id;
        push @{$state->{args}} => $id;

        # The return is ignored.
        return;
    }

    sub record {
        my $self = shift;
        my ($job_id, $record_arg_from_assign) = @_;

        # The ID from $state->{record}->{$pkg} in assign.
        my $id = $record_arg_from_assign;

        # Update our internal state to reflect the new ID.
        $self->{ID} = $id;

        # Add a mapping of what job ID gets what integer ID.
        $self->{ID_TO_JOB_ID}->{$id}     = $job_id;
        $self->{JOB_ID_TO_ID}->{$job_id} = $id;

        print "RECORD: $id = $job_id\n";

        # The return is ignored
    }

    sub tick {
        my $self = shift;

        # This is called by only 1 process at a time and gives you a way to do
        # extra stuff at a regular interval without other processes trying to
        # do the same work at the same time.
        # For example, if a database is left in a dirty state after it is
        # released, you can fire off a cleanup action here knowing no other
        # process will run it at the same time. You can also be sure no record
        # messages will be sent while this sub is running as the process it
        # runs in has a lock.

        ...
    }


    sub release {
        my $self = shift;
        my ($job_id) = @_;

        # Clear the internal mapping, the integer ID is now free. Theoretically it
        # can be reused, but this example is not that complex.
        my $id = delete $self->{JOB_ID_TO_ID}->{$job_id};

        # This is called for all tests that complete, even if they did not use
        # this resource, so we return if the job_id is not applicable.
        return unless defined $id;

        delete $self->{ID_TO_JOB_ID}->{$id};

        print "  FREE: $id = $job_id\n";

        # The return is ignored
    }

    sub cleanup {
        my $self = shift;

        print "CLEANUP!\n";
    }

    1;

The print statements generated will look like this when running 2 tests concurrently:

    yath test -R Foo -j2 t/testA.t t/testB.t
    [...]
    (INTERNAL)     ASSIGN: 1 = 4F7CF5F6-E43F-11EA-9199-24FCBF610F44
    (INTERNAL)     RECORD: 1 = 4F7CF5F6-E43F-11EA-9199-24FCBF610F44
    (INTERNAL)     ASSIGN: 2 = E19CD98C-E436-11EA-8469-8DF0BF610F44
    (INTERNAL)     RECORD: 2 = E19CD98C-E436-11EA-8469-8DF0BF610F44
    (INTERNAL)       FREE: 1 = 4F7CF5F6-E43F-11EA-9199-24FCBF610F44
    (INTERNAL)       FREE: 2 = E19CD98C-E436-11EA-8469-8DF0BF610F44
    (INTERNAL)     CLEANUP!
    [...]

Depending on the tests run the 'FREE' prints may be out of order.

=head1 WORKFLOW

=head2 HOW STATE IS MANAGED

Depending on your preload configuration, yath may have several runners
launching tests. If a runner has nothing to do it will lock the queue and try
to find the next test that should be run. Only 1 of the runners will be in
control of the queue at any given time, but the control of the queue may pass
between runners. To manage this there is a mechanism to record messages that
allow each runner to maintain a copy of the current state.

=head2 CHECK IF RESOURCES ARE AVAILABLE

Each runner will have an instance of your resource class. When the runner is in
control of the queue, and wants to designate the next test to run, it will
check with the resource classes to make sure the correct resources are
available. To do that it will call C<available($task)> on each resource
instance.

The C<$task> will contain the specification for the test, it is a hashref, and
you B<SHOULD NOT> modify it. The only key most people care about is the 'file'
key, which has the test file that will be run if resources are available.

If resources are available, or if the specific file does not need the resource,
the C<available()> method should return true. If the file does need your
resource(s), and none are available, this should return false. If any resource
class returns false it means the test cannot be run yet and the runner will
look for another test to run.

=head2 ASSIGN A RESOURCE

If the runner has determined the test can be run, and all necessary resources
are available, it will then call C<assign($task, $state)> on all resource class
instances. At this time the resource class should decide what resource(s) to
assign to the class.

B<CRITICAL NOTE:> the C<assing()> method B<MUST NOT> alter any internal state
on the resource class instance. State modification must wait for the
C<record()> method to be called. This is because the C<assign()> method is only
called in one runner process, the C<record()> method call will happen in every
runner process to insure they all have the same internal state.

The assign() sub should modify the C<$state> hash, which has 3 keys:

=over 4

=item env_vars => {}

Env vars to set for the test

=item args => []

Arguments to pass to the test

=item record => ...

Data needed to record the state change for resource classes. Can be a scalar,
hashref, arrayref, etc. It will be serialized to JSON to be passed between
processes.

=back

=head2 RECORD A RESOURCE

Once a resource is assigned, a message will be sent to all runner processes
B<INCLUDING THE ONE THAT DID THE ASSIGN> that says it should call
C<record($job_id, $record_val)> on your resource class instance. Your resource
class instance must use this to update the state so that once done ALL
processes will have the proper internal state.

The C<$record_val> is whatever you put into C<< $state->{record} >> in the
C<assign()> method above.

=head2 QUEUE MANAGEMENT IS UNLOCKED

Once the above has been done, queue management will be unlocked. You can be
guarenteed that only one process will be run the C<available()>, and
C<assign()> sequence at a time, and that they will be called in order, though
C<assign()> may not be called if another resource was not available. If
C<assign()> is called, you can be guarenteed that all processes, including the
one that called C<assign()> will have their C<record()> called with the proper
argument B<BEFORE> they try to manage the queue (which is the only place
resources are checked or assigned).

=head2 RELEASE A RESOURCE

Whenever a process that is using a resource exits, the runner that waits on
that process will I<eventually> send an IPC message announcing that the job_id
has completed. Every time a job_id completes the C<release($job_id)> method
will be called on your resource class in all runner processes. This allows the
state to be updated to reflect the freed resource.

You can be guarenteed that any process that locks the queue to run a new
test will eventually see the message. The message may come in during a loop
that is checking for resources, in which case the state will not reflect the
resource being available, however in such cases the loop will end and be
called again later with the message having been receieved. There will be no
deadlock due to a queue manager waiting for the message.

There are no guarentees about what order resources will be released in.

=head1 METHODS

=over 4

=item $class->setup($settings)

This will be called once before the runner forks or initialized per-process
instances. If you have any "setup once" tasks to initialize resources before
tests run this is a good place to do it.

This runs immedietly after plugin setup() methods are called.

B<NOTE:> Do not rely on recording any global state here, the runner and
per-process instances may not be forked from the process that calls setup().

=item $res = $class->new(settings => $settings);

A default new method, returns a blessed hashref with the settings key set to
the L<Test2::Harness::Settings> instance.

=item $val = $res->available(\%task)

B<DO NOT MODIFY ANY INTERNAL STATE IN THIS METHOD>

B<DO NOT MODIFY THE TASK HASHREF>

Returns a positive true value if the resource is available.

Returns false if the resource is not available, but will be in the future (IE
in use by another test, but will be free when that test is done).

Returns a negative value if the resource is not available and never will be.
This will cause any tests dependent on the resource to be skipped.

The only key in C<\%task> hashref that most resources will care about is the
C<'file'> key, which contains the test file to be run.

=item $res->assign(\%task, \%state)

B<DO NOT MODIFY THE TASK HASHREF>

B<DO NOT MODIFY ANY INTERNAL STATE IN THIS METHOD>

If the task does not need any resources you may simply return.

If resources are needed you should deduce what resources to assign.

You should put any data needed to update the internal state of your resource
instance in the C<< $state->{record} >> hash key. It B<WILL> be serialized to
JSON before being used as an argument to C<record()>.

    $state->{record} = $id;

If you do not set the 'record' key, or set it to undef, then the C<record()>
method will not be called.

If your tests need to know what resources to use, you may set environment
variables and/or command line arguments to pass into the test (C<@ARGV>).

    $state->{env_vars}->{FOO_ID} = $id;
    push @{$state->{args}} => $id;

The C<\%state> hashref is used only by your instance, you are free to fully
replace the 'env_vars' and 'args' keys. They will eventually be merged into a
master state along with those of other resources, but this ref is exclusive to
you in this method.

=item $inst->record($job_id, $record_arg_from_assign)

B<NOTE: THIS MAY BE CALLED IN MUTLIPLE PROCESSES CONCURRENTLY>.

This will be called in all processes so that your instance can update any
internal state.

The C<$job_id> variable contains the id for the job to which the resource was
assigned. You should use this to record any internal state. The $job_id will be
passed to C<release()> when the job completes and no longer needs the resource.

This is intended only for modifying internal state, you should not do anything
in this sub that will explode if it is also done in another process at the same
time with the same arguments. For example creating a database should not be
done here, multiple processes will fight to do the create. The creation, if
necessary should be done in C<assign()> which will be called in only one
process.

=item $inst->release($job_id)

B<NOTE: THIS MAY BE CALLED IN MUTLIPLE PROCESSES CONCURRENTLY>.

This will be called for every test job that completes, even if it did not use
this resource. If the job_id did not use the resource you may simply return,
otherwise update the internal state to reflect that the resource is no longer
in use.

This is intended only for modifying internal state, you should not do anything
in this sub that will explode if it is also done in another process at the same
time with the same arguments. For example deleting a database should not be
done here, multiple processes will fight to do the delete. C<assign()> is the
only method that will be run in a single process, so if a database needs to be
cleaned before it can be used you should clean it there. Any final cleanup
should be done in C<cleanup()> which will only be called by one process at the
very end.

=item $inst->cleanup()

This will be called once by the parent runner process just before it exits.
This is your chance to do any final cleanup tasks such as deleting databases
that are no longer going to be used by tests as no more will be run.

=item $inst->tick()

This is called by only 1 process at a time and gives you a way to do extra
stuff at a regular interval without other processes trying to do the same work
at the same time.

For example, if a database is left in a dirty state after it is released, you
can fire off a cleanup action here knowing no other process will run it at the
same time. You can also be sure no record messages will be sent while this sub
is running as the process it runs in has a lock.

=item $inst->refresh()

Called once before each resource-request loop. This is your chance to do things
between each set of requests for resources.

=item $bool = $inst->job_limiter()

True if your resource is intended as a job limiter (IE alternative to
specifying -jN at the command line).

=item $int = $inst->job_limiter_max()

Max number of jobs this will allow at the moment, if this resource is a job
limiter.

=item $bool = $inst->job_limiter_at_max()

True if the limiter has reached its maximum number of running jobs. This is
used to avoid a resource-allocation loop as an optimization.

=item $number = $inst->sort_weight()

Used to sort resources if you want them to be checked in a specific order. For
most resources this defaults to 50. For job_limiter resources this defaults to
100. Lower numbers are sorted to the front of the list, IE they are aquired
first, before other resources.

Job slots are sorted later (100) so that we do not try to grab a job slot if
other resources are not available.

Most of the time order will not matter, however with Shared job slots we have a
race with other test runs to get slots, and checking availability is enough to
consume a slot, even if other resources are not available.

=item $string = $inst->status_lines()

Get a (multi-line) string with status info for this resource. This is used to
populate the output for the C<yath resources> command.

The default implementation will build a string from the data provided by the
C<status_data()> method.

=item $arrayref = $inst->status_data()

The default implementation returns an empty list.

This should return status data that looks like this:

    return [
        {
            title  => "Resource Group Title",
            tables => [
                {
                    header => \@columns,
                    rows   => [
                        \@row1,
                        \@row2,
                    ],

                    # Optional fields
                    ##################

                    # formatting for fields in rows
                    format => [undef, undef, 'duration', ...],

                    # Title for the table
                    title => "Table Title",

                    # Options to pass to Term::Table if/when it the data is used in Term::Table
                    term_table_opts => {...},
                },

                # Any number of tables is ok
                {...},
            ],
        },

        # Any number of groups is ok
        {...},
    ];

Currently the only supported formats are 'default' (undef), and 'duration'.
Duration takes a stamp and tells you how much time has passed since the stamp.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
