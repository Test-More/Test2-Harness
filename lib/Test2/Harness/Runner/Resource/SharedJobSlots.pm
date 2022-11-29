package Test2::Harness::Runner::Resource::SharedJobSlots;
use strict;
use warnings;

our $VERSION = '1.000136';

use YAML::Tiny;
use Test2::Harness::Runner::Resource::SharedJobSlots::State;

use App::Yath::Util qw/find_in_updir/;
use Sys::Hostname qw/hostname/;
use Time::HiRes qw/time/;
use List::Util qw/min sum0/;
use Carp qw/confess/;

use parent 'Test2::Harness::Runner::Resource';
use Test2::Harness::Util::HashBase qw{
    <settings
    <state
    <config
    <runner_id
    <runner_pid
    <job_limiter_max
    <observe
};

sub job_limiter { 1 }

sub new {
    my $class = shift;
    my $self = bless {@_}, $class;
    $self->init();
    return $self;
}

sub get_config {
    my $class = shift;
    my ($config_file) = @_;

    return () unless $config_file;

    $config_file = find_in_updir($config_file) if $config_file !~ m{(/|\\)} && ! -e $config_file;

    return () unless $config_file && -e $config_file;

    my $config = YAML::Tiny->read($config_file) or die "Could not read '$config_file'";
    $config = $config->[0]; # First doc only
    for my $host (hostname(), 'DEFAULT') {
        my $host_conf = $config->{$host} or next;
        return ($config_file, $host, $host_conf);
    }

    return ();
}

sub init {
    my $self     = shift;
    my $settings = $self->{+SETTINGS};

    my $config_path = $settings->runner->shared_jobs_config;
    my ($config_file, $host, $host_conf) = $self->get_config($config_path);
    die "Could not find shared jobs config '$config_path'.\n"
        unless $config_file;

    die "Could not find '" . hostname() ."' or 'DEFAULT' settings in '$config_file'.\n"
        unless $host && $host_conf;

    if ($host eq 'DEFAULT' && !$host_conf->{no_warning}) {
        warn <<"        EOT";
Using the 'DEFAULT' shared-slots host config.
You may want to add the current host to the config file.
To silence this warning, set the 'no_warning' key to true in the DEFAULT host config.
Config file: $config_file
        EOT
    }

    my $sort = $host_conf->{algorithm} // 'fair';
    if ($sort =~ m/^(.*)::([^:]+)$/) {
        my ($mod, $sub) = ($1, $2);
        require(mod2file($mod));
    }
    else {
        my $short = $sort;
        $sort = "request_sort_$sort";
        die "'$short' is not a valid algorith (in file '$config_file' under hist '$host' key 'algorithm'). Must be 'fair', 'first', 'greedy', or a Fully::Qualified::Module::function_name."
            unless Test2::Harness::Runner::Resource::SharedJobSlots::State->can($sort);
    }

    my $runner_id  = $self->{+RUNNER_ID}  //= $settings->runner->runner_id if $settings->check_prefix('runner');
    my $runner_pid = $self->{+RUNNER_PID} //= $Test2::Harness::Runner::RUNNER_PID // $App::Yath::Command::runner::RUNNER_PID;

    my $prefix = $settings->debug->procname_prefix // '';
    my $name   = $settings->harness->project       // '';

    my $dir;
    if (my $path = $settings->harness->config_file) {
        if ($path =~ m{^(.*)/[^/]+$}) {
            $dir = $1;
        }
    }

    $dir //= $settings->harness->cwd;

    unless ($name) {
        $name = $dir;
        $name =~ s{^.*/}{};
    }

    $name = "$prefix-$name" if $prefix;

    $self->{+JOB_LIMITER_MAX} = min(grep { $_ } $host_conf->{max_slots_per_run}, $settings->runner->job_count);

    my $max_slots   = min($self->settings->runner->job_count,     $host_conf->{max_slots}         // die("'max_slots' not set in '$config_file' for host '$host'.\n"));
    my $max_per_run = min($self->settings->runner->job_count,     $host_conf->{max_slots_per_run} // die("'max_slots_per_run' not set in '$config_file' for host '$host'.\n"));
    my $max_per_job = min($self->settings->runner->slots_per_job, $host_conf->{max_slots_per_job} // die("'max_slots_per_job' not set in '$config_file' for host '$host'.\n"));

    $self->{+STATE} = Test2::Harness::Runner::Resource::SharedJobSlots::State->new(
        dir               => $dir,
        name              => $name,
        runner_id         => $runner_id,
        runner_pid        => $runner_pid,
        state_umask       => $host_conf->{state_umask} // 0007,
        state_file        => $host_conf->{state_file} // die("'state_file' not set in '$config_file' for host '$host'.\n"),
        max_slots         => $max_slots,
        max_slots_per_job => $max_per_job,
        max_slots_per_run => $max_per_run,
        request_sort      => $sort,
    );

    $self->{+CONFIG} = $host_conf;

    return;
}

# Disable this short-circuit otherwise we may never queue a request!
sub job_limiter_at_max { 0 }

sub refresh { $_[0]->{+STATE}->update_registration }

sub available {
    my $self = shift;
    my ($task) = @_;

    my $concurrency = min(grep { $_ } ($task->{slots_per_job} // 1), @{$self->{+CONFIG}}{qw/max_slots_per_run max_slots_per_job/}, $self->settings->runner->slots_per_job, $self->settings->runner->job_count);
    $concurrency ||= 1;

    # Make or update a request, then tell us if the request is ready
    return $self->{+STATE}->request_slots(
        job_id => $task->{job_id},
        file   => $task->{rel_file} // $task->{file} // $task->{job_name},
        count  => $concurrency,
    );
}

sub assign {
    my $self = shift;
    my ($task, $state) = @_;

    return if $self->{+OBSERVE};

    # Grab the reservation
    my $info = $self->{+STATE}->get_ready_request($task->{job_id})
        or die "Could not get requested slots!\n";

    $state->{env_vars}->{T2_HARNESS_MY_JOB_CONCURRENCY} = $info->{count};

    return $info;
}

sub record { } # NOOP

sub release {
    my $self = shift;
    my ($job_id) = @_;

    return if $self->{+OBSERVE};

    $self->{+STATE}->release_slots($job_id);
    return;
}

sub status_lines {
    my $self = shift;

    my $state     = $self->state;
    my $status    = $state->status;
    my $runner_id = $state->runner_id;

    my $used  = $status->{used_count}      // 0;
    my $free  = $status->{available_count} // 0;
    my $pend  = $status->{request_count}   // 0;
    my $total = $used + $free;

    my $our_assigned = $status->{used}->{$runner_id}    // 0;
    my $our_pending  = $status->{pending}->{$runner_id} // 0;

    my $details = "";
    for my $runner (sort { $a->{ord} <=> $b->{ord} } values %{$status->{state}->{runners}}) {
        my $jobs = "";
        my $count = 0;

        for my $set ($status->{state}->{assigned}, $status->{state}->{queue}) {
            next unless $set;
            my $set2 = $set->{$runner->{runner_id}} or next;

            for my $job (sort { $a->{ord} <=> $b->{ord} } values %$set2) {
                $count += $job->{count};
                my $stamp = $job->{assign_stamp};
                my $runtime = $stamp ? sprintf("%8.2fs", time - $stamp) : '   --   ';
                $jobs .= "     $runtime | Slots: $job->{count} | " . ($job->{file} // $job->{job_id}) . "\n";
            }
        }

        my $pend = $status->{pending}->{$runner->{runner_id}} // 0;

        next unless $pend || $count;

        $details .= <<"        EOT"
      ** $runner->{ord}: $runner->{user} - $runner->{name} **
         Pending: $pend
        Assigned: $count
$jobs

        EOT
    }

    my $out = <<"    EOT";
   ** System Wide Summary **
    Total Shared Slots: $total
     Used Shared Slots: $used
     Free Shared Slots: $free
  Pending Shared Slots: $pend
  ---------------------------

   ** Our Summary **
  Assigned Slots: $our_assigned
   Pending Slots: $our_pending
  ---------------------------

   ** Runners **
$details
    EOT

    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::Resource::SharedJobSlots - limit the job count (-j) per machine

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

=item max_slots_per_job: 2

Max slots a specific test job (test file) can use.

=item algorithm: fair

=item algorithm: first

=item algorithm: greedy

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

=item greedy

Not recommended, no known good use cases. This algorithm has each run
prioritize its own tests, this is an unpredictable algorithm that can lead to
one runner gobbling up the maximum allowed slots as fast as possible.

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
instance of C<Test2::Harness::Runner::Resource::SharedJobSlots::State>.
$state_data is a hashref like you get from C<< $state_object->state() >> which
is useful if you want to know how many slots each runner is using for a 'fair'
style algorth.

Take a look at the C<request_sort_XXX> methods on
C<Test2::Harness::Runner::Resource::SharedJobSlots::State> which implement the
3 original sorting methods.

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

Copyright 2022 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
