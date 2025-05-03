package App::Yath::Resource::SharedJobSlots;
use strict;
use warnings;

our $VERSION = '2.000005';

use YAML::Tiny;
use File::Spec;

use Time::HiRes qw/time/;
use List::Util qw/min/;
use Carp qw/confess/;

use App::Yath::Resource::SharedJobSlots::State;
use App::Yath::Resource::SharedJobSlots::Config;

use Test2::Harness::Util qw/find_in_updir/;

use Getopt::Yath;

option_group {group => 'resource', category => "Resource Options"} => sub {
    option shared_jobs => (
        type => 'Bool',
        maybe => 1,
        description => "Enable or Disable shared job slots",
    );

    option shared_jobs_config => (
        type          => 'Scalar',
        default       => '.sharedjobslots.yml',
        long_examples => [' .sharedjobslots.yml', ' relative/path/.sharedjobslots.yml', ' /absolute/path/.sharedjobslots.yml'],
        description   => 'Where to look for a shared slot config file. If a filename with no path is provided yath will search the current and all parent directories for the name.',
    );

    option_post_process 40 => \&shared_post_process;
};

sub shared_post_process {
    my ($options, $state) = @_;

    my $settings = $state->{settings};
    return unless $settings->check_group('resource');

    my $resource = $settings->resource;

    my $required = 0;
    if (defined($resource->shared_jobs)) {
        return unless $resource->shared_jobs;
        $required = 1;
    }

    my $base_name = $resource->shared_jobs_config;

    unless ($base_name && (-e $base_name || find_in_updir($base_name))) {
        return unless $required;
        die "--shared-jobs specified, but could not find a config file!\n";
    }

    push @{$resource->classes->{'App::Yath::Resource::SharedJobSlots'} //= []} => (shared_jobs_config => $base_name);
}

use parent 'App::Yath::Resource';
use Test2::Harness::Util::HashBase qw{
    <slots
    <job_slots
    <shared_jobs_config

    <state
    <config
    <runner_id
    <runner_pid
    <observe
};

sub spawns_process { 0 }
sub is_job_limiter { 1 }

sub resource_name { 'jobslots' }
sub resource_io_tag { 'JOBSLOTS' }

sub applicable { 1 }

sub refresh { $_[0]->{+STATE}->update_registration }

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $settings = $self->{+SETTINGS};

    my $sconf = App::Yath::Resource::SharedJobSlots::Config->find(base_name => $self->{+SHARED_JOBS_CONFIG})
        or die "Could not find shared jobs config.\n";

    my $prefix  = $settings->harness->procname_prefix // '';
    my $project = $settings->yath->project            // '';

    my $dir;
    if (my $path = $settings->yath->config_file) {
        my ($vol, $cdir, $file) = File::Spec->splitpath($path);
        $dir = File::Spec->catpath($vol, $cdir);
    }
    $dir //= $settings->yath->cwd;

    ($project) = reverse(File::Spec->splitdir($dir))
        unless $project;

    $project = "$prefix-$project" if $prefix;

    $self->{+RUNNER_PID} //= $$;
    $self->{+RUNNER_ID}  //= join('-', grep { $_ } $ENV{USER}, $project, $$);

    $self->{+STATE} = App::Yath::Resource::SharedJobSlots::State->new(
        dir        => $dir,
        project    => $project,
        runner_id  => $self->{+RUNNER_ID},
        runner_pid => $self->{+RUNNER_PID},

        state_umask           => $sconf->state_umask,
        state_file            => $sconf->state_file,
        algorithm             => $sconf->algorithm,
        max_slots             => $sconf->max_slots,
        max_slots_per_job     => $sconf->max_slots_per_job,
        max_slots_per_run     => $sconf->max_slots_per_run,
        min_slots_per_run     => $sconf->min_slots_per_run,
        default_slots_per_run => $sconf->default_slots_per_run,
        default_slots_per_job => $sconf->default_slots_per_job,

        my_max_slots         => min($self->{+SLOTS},     $sconf->max_slots),
        my_max_slots_per_job => min($self->{+JOB_SLOTS}, $sconf->max_slots_per_job),
    );

    $self->{+CONFIG} = $sconf;

    return;
}

sub _job_concurrency {
    my $self = shift;
    my ($job) = @_;

    my $rmax  = $self->{+SLOTS};
    my $jmax  = $self->{+JOB_SLOTS};
    my $srmax = $self->{+CONFIG}->max_slots_per_run;
    my $sjmax = $self->{+CONFIG}->max_slots_per_job;

    my $tmin = $job->test_file->check_min_slots // 1;
    my $tmax = $job->test_file->check_max_slots // $tmin;

    my $max = min($tmax, $sjmax, $srmax, $jmax, $rmax);

    # Invalid condition, minimum is more than our maximim
    return       if $tmin > $max;
    $max = $tmin if $max < $tmin;

    return [$tmin, $max];
}

sub available {
    my $self = shift;
    my ($id, $job) = @_;

    my $con = $self->_job_concurrency($job);
    return -1 unless $con;

    return $self->{+STATE}->allocate_slots(con => $con, job_id => $id);
}

sub assign {
    my $self = shift;
    my ($id, $job, $env) = @_;

    return if $self->{+OBSERVE};

    my $tf = $job->test_file;

    my $info = $self->{+STATE}->assign_slots(
        job => {
            job_id => $id,
            file   => $tf->relative // $tf->file // $id,
        },
    );

    $env->{T2_HARNESS_MY_JOB_CONCURRENCY} = $info->{count};

    return $env;
}

sub release {
    my $self = shift;
    my ($id, $job) = @_;

    return if $self->{+OBSERVE};

    $self->{+STATE}->release_slots(job_id => $id);

    return;
}

sub status_data {
    my $self = shift;

    my @groups;

    my $runners = $self->state->state->{runners};

    my $global_status = {
        todo     => 0,
        allotted => 0,
        assigned => 0,
        pending  => 0,
    };

    my $time = time;

    for my $runner (sort { $a->{added} <=> $b->{added} } values %$runners) {
        my $run_status = {
            todo     => $runner->{todo},
            allotted => $runner->{allotment},
            assigned => 0,
            pending  => 0,
        };

        my $job_table = {
            header => [qw/Runtime Slots Name/],
            format => ['duration', undef, undef],
            rows   => [],
        };

        for my $job (sort { $a->{started} <=> $b->{started} } values %{$runner->{assigned}}) {
            $run_status->{assigned} += $job->{count};
            my $stamp = $job->{started};
            my $slots = $job->{count};

            push @{$job_table->{rows}} => [$time - $stamp, $slots, $job->{file} // $job->{job_id}];
        }

        $run_status->{pending} = $runner->{allotment} - $run_status->{assigned};

        $global_status->{$_} += $run_status->{$_} for keys %$global_status;

        my $run_table = {
            header => [qw/Todo Allotted Assigned Pending/],
            rows   => [[$run_status->{todo}, $run_status->{allotted}, $run_status->{assigned}, $run_status->{pending}]],
        };

        push @groups => {
            title  => "$runner->{user} - $runner->{name} - $runner->{runner_id}",
            tables => [
                $run_table,
                $job_table,
            ],
        };
    }

    $global_status->{total} = $self->state->{max_slots};
    $global_status->{free}  = $global_status->{total} - ($global_status->{assigned} + $global_status->{pending});
    $global_status->{free}  = "$global_status->{free} (Minimum per-run overrides max slot count in some cases)" if $global_status->{free} < 0;

    unshift @groups => {
        title => 'System Wide Summary',
        tables => [
            {
                header => ['Todo', 'Total Shared Slots', 'Allotted Shared Slots', 'Assigned Shared Slots', 'Pending Shared Slots', 'Free Shared Slots'],
                rows   => [[ @{$global_status}{qw/todo total allotted assigned pending free/} ]],
            }
        ],
    };

    return \@groups;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Resource::SharedJobSlots - limit the job count (-j) per machine

=head1 SYNOPSIS

B<This synopsis is not about using this in code, but rather how to use it on the command line.>

In order to use SharedJobSlots you must ether create the C<.sharedjobslots.yml>
file, or provide the C<--shared-jobs-config PATH> argument on the command line.
The C<PATH> must be a path to a yaml file with configuration specifications for
job sharing.

=head1 CONFIG FILE

Config files for shared slots must be yaml file, they must also be parsable by
L<YAML::Tiny>, which implements a subset of yaml.

Here is an example config file:

    ---
    DEFAULT:
      state_file: /tmp/yath-slot-state
      max_slots:  8
      max_slots_per_job: 2
      max_slots_per_run: 6

    myhostname:
      state_file: /tmp/myhostname-slot-state
      max_slots:  16
      max_slots_per_job: 4
      max_slots_per_run: 12

=head2 TOP LEVEL KEYS (HOSTNAMES)

All top level keys are hostnames. When the config is read the settings for the
current hostname will be used. If the hostname is not defined then the
C<DEFAULT> host will be read. If there is no C<DEFAULT> host defined an
exception will be thrown.

=head2 CONFIG OPTIONS

Each option must be specified under a hostname, none of these are valid on
their own.

=over 4

=item state_file: /path/to/shared/state/file

B<REQUIRED>

This specifies the path to the shared state file. All yath processes by all
users who are sharing slots need read+write access to this file.

=item state_umask: 0007

Defaults to C<0007>. Used to set the umask of the state file as well as the
lock file.

=item max_slots: 8

Max slots system-wide for all users to share.

=item max_slots_per_run: 4

Max slots a specific test run can use.

=item min_slots_per_run: 0

Minimum slots per run.

Set this if you want to make sure that all runs get at least N slots,
B<EVEN IF IT MEANS GOING OVER THE SYSTEM-WIDE MAXIMUM!>.

This defaults to 0.

=item max_slots_per_job: 2

Max slots a specific test job (test file) can use.

=item default_slots_per_run: 4

If the user does not specify a number of slots, use this as the default.

=item default_slots_per_job: 2

If the user does not specify a number of job slots, use this as the default.

=item algorithm: fair

=item algorithm: first

=item algorithm: Fully::Qualified::Module::function_name

Algorithm to use when assigning slots. 'fair' is the default.

=back

=head3 ALGORITHMS

These are algorithms that are used to decide which test runs get which slots.

=over 4

=item fair

B<DEFAULT>

This algorithm tries to balance slots so that all runs share an equal fraction
of available slots. If there are not enough slots to go around then priority
goes to oldest runs, followed by oldest requests.

=item first

Priority goes to the oldest run, followed by the next oldest, etc. If the run
age is not sufficient to sort requests this will fall back to 'fair'.

This is mainly useful for CI systems or batched test boxes. This will give
priority to the first test run started, so additional test runs will not
consume slots the first run wants to use, but if the first run is winding down
and does not need all the slots, the second test run can start using only the
spare slots.

Use this with ordered test runs where you do not want a purely serial run
order.

=item Fully::Qualified::Module::function_name

You can specify custom algorithms by giving fully qualified subroutine names.

=back

Example custom algorithm:

    sub custom_sort {
        my ($state_object, $state_data, $a, $b) = @_;

        return 1 if a_should_come_first($a, $b);
        return -1 if b_should_come_first($a, $b);
        return 0 if both_have_same_priority($a, $b);

        # *shrug*
        return 0;
    }

Ultimately this is used in a C<sort()> call, usual rules apply, return should
be 1, 0, or -1. $a and $b are the 2 items being compared. $state_object is an
instance of C<App::Yath::Resource::SharedJobSlots::State>.
$state_data is a hashref like you get from C<< $state_object->state() >> which
is useful if you want to know how many slots each runner is using for a 'fair'
style algorth.

Take a look at the C<request_sort_XXX> methods on
C<App::Yath::Resource::SharedJobSlots::State> which implement the
3 original sorting methods.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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

See L<http://dev.perl.org/licenses/>

=cut

=pod

=cut POD NEEDS AUDIT

