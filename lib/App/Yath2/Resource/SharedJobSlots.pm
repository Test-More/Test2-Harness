package App::Yath2::Resource::SharedJobSlots;
use strict;
use warnings;

our $VERSION = '2.000011';

use File::Spec;
use Time::HiRes qw/time/;
use List::Util qw/min/;
use Carp qw/croak/;

use App::Yath2::Resource::SharedJobSlots::State;
use App::Yath2::Resource::SharedJobSlots::Config;

use Object::HashBase qw{
    <slots
    <job_slots
    <shared_jobs_config

    <host
    <project
    <cwd
    <procname_prefix
    <observe

    <runner_id
    <runner_pid

    <state
    <config
    +broken
    +permanent_broken
    +paused
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';

sub is_job_limiter { 1 }

# Participates for every job the scheduler presents to it; the
# algorithm inside $state decides per-job grants.
sub needed { 1 }

sub resource_name { 'sharedjobslots' }

sub init {
    my $self = shift;

    croak "'slots' is a required attribute"
        unless defined $self->{+SLOTS} && $self->{+SLOTS} =~ m/^\d+$/ && $self->{+SLOTS} > 0;

    $self->{+JOB_SLOTS} //= 1;
    croak "'job_slots' must be a positive integer"
        unless $self->{+JOB_SLOTS} =~ m/^\d+$/ && $self->{+JOB_SLOTS} > 0;

    my $sconf = App::Yath2::Resource::SharedJobSlots::Config->find(
        base_name => $self->{+SHARED_JOBS_CONFIG},
        (defined $self->{+HOST} ? (host => $self->{+HOST}) : ()),
    ) or die "Could not find shared jobs config.\n";

    # Runner identity defaults: user + project + pid so concurrent
    # yath invocations from the same checkout still have unique
    # runner_ids (the pid disambiguates). The caller may override any
    # of these at construction time.
    my $prefix  = $self->{+PROCNAME_PREFIX} // '';
    my $project = $self->{+PROJECT}         // '';

    my $dir = $self->{+CWD};
    $dir //= do {
        require Cwd;
        Cwd::getcwd();
    };

    unless ($project) {
        ($project) = reverse(File::Spec->splitdir($dir));
    }

    $project = "$prefix-$project" if $prefix;

    $self->{+RUNNER_PID} //= $$;
    $self->{+RUNNER_ID}  //= join('-', grep { $_ } $ENV{USER}, $project, $$);

    $self->{+PROJECT} = $project;
    $self->{+CWD}     = $dir;

    $self->{+STATE} = App::Yath2::Resource::SharedJobSlots::State->new(
        dir        => $dir,
        name       => $project,
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

# Refresh our heartbeat on the state file. Harness tick loops call this
# periodically so other runners see us as alive.
sub refresh { $_[0]->{+STATE}->update_registration }

sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }
sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }

sub mark_broken           { $_[0]->{+BROKEN}           = 1 }
sub mark_paused           { $_[0]->{+PAUSED}           = 1 }
sub mark_resumed          { $_[0]->{+BROKEN}           = 0; $_[0]->{+PAUSED} = 0 }
sub mark_permanent_broken { $_[0]->{+PERMANENT_BROKEN} = 1; $_[0]->{+BROKEN} = 1 }

# Compute (min, max) slot bounds for a job combining the resource-wide
# caps (slots / job_slots / config caps) with any per-test declaration.
sub _job_concurrency {
    my $self = shift;
    my ($job) = @_;

    my $rmax  = $self->{+SLOTS};
    my $jmax  = $self->{+JOB_SLOTS};
    my $srmax = $self->{+CONFIG}->max_slots_per_run;
    my $sjmax = $self->{+CONFIG}->max_slots_per_job;

    my $tf = $job->test_file;

    # test_file->min_slots / max_slots are the in-tree API (see JobCount).
    # Support the old check_min_slots / check_max_slots names too so tests
    # using the legacy TestFile shape keep working.
    my $tmin = $tf->can('min_slots') ? ($tf->min_slots // 1)     : ($tf->can('check_min_slots') ? ($tf->check_min_slots // 1)     : 1);
    my $tmax = $tf->can('max_slots') ? ($tf->max_slots // $tmin) : ($tf->can('check_max_slots') ? ($tf->check_max_slots // $tmin) : $tmin);

    my $max = min($tmax, $sjmax, $srmax, $jmax, $rmax);

    # Invalid condition, minimum is more than our maximum
    return if $tmin > $max;

    $max = $tmin if $max < $tmin;

    return [$tmin, $max];
}

sub available {
    my $self = shift;
    my (%p) = @_;

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";

    my $con = $self->_job_concurrency($job);
    return -1 unless $con;

    return $self->{+STATE}->allocate_slots(con => $con, job_id => $id);
}

sub assign {
    my $self = shift;
    my (%p) = @_;

    return if $self->{+OBSERVE};

    my $id  = $p{id}  or croak "'id' is required";
    my $job = $p{job} or croak "'job' is required";
    my $env = $p{env} or croak "'env' hashref is required";

    my $tf = $job->test_file;
    my $file;
    if ($tf->can('relative')) {
        $file = $tf->relative;
    }
    $file //= $tf->can('file') ? $tf->file : undef;
    $file //= $id;

    my $info = $self->{+STATE}->assign_slots(
        job => {
            job_id => $id,
            file   => $file,
        },
    );

    $env->{T2_HARNESS_MY_JOB_CONCURRENCY} = $info->{count};

    return $info->{count};
}

sub release {
    my $self = shift;
    my (%p) = @_;

    return if $self->{+OBSERVE};

    my $id = $p{id} or croak "'id' is required";

    $self->{+STATE}->release_slots(job_id => $id);

    return;
}

sub status {
    my $self = shift;

    return {
        resource    => $self->resource_name,
        state_file  => $self->{+CONFIG} ? $self->{+CONFIG}->state_file  : undef,
        config_file => $self->{+CONFIG} ? $self->{+CONFIG}->config_file : undef,
        host        => $self->{+CONFIG} ? $self->{+CONFIG}->host        : $self->{+HOST},
        runner_id   => $self->{+RUNNER_ID},
        runner_pid  => $self->{+RUNNER_PID},
        slots       => $self->{+SLOTS},
        job_slots   => $self->{+JOB_SLOTS},
        broken      => $self->is_broken,
        paused      => $self->is_paused,
        permanent   => $self->is_permanent_broken,
        assignments => $self->_assignments_snapshot,
        groups      => $self->status_data,
    };
}

sub _assignments_snapshot {
    my $self = shift;

    my @out;
    my $state = $self->{+STATE}->state;
    my $entry = $state->{runners}->{$self->{+RUNNER_ID}} or return \@out;

    for my $job (sort { ($a->{started} // 0) <=> ($b->{started} // 0) } values %{$entry->{assigned} // {}}) {
        push @out => {
            job_id => $job->{job_id},
            file   => $job->{file},
            count  => $job->{count},
            stamp  => $job->{started},
        };
    }

    return \@out;
}

# Per-runner tabular summary suitable for the `yath resources`
# renderer. Ported verbatim from old/'s status_data.
sub status_data {
    my $self = shift;

    my @groups;

    my $runners = $self->{+STATE}->state->{runners} // {};

    my $global_status = {
        todo     => 0,
        allotted => 0,
        assigned => 0,
        pending  => 0,
    };

    my $time = time;

    for my $runner (sort { ($a->{added} // 0) <=> ($b->{added} // 0) } values %$runners) {
        my $run_status = {
            todo     => $runner->{todo}      // 0,
            allotted => $runner->{allotment} // 0,
            assigned => 0,
            pending  => 0,
        };

        my $job_table = {
            header => [qw/Runtime Slots Name/],
            format => ['duration', undef, undef],
            rows   => [],
        };

        for my $job (sort { ($a->{started} // 0) <=> ($b->{started} // 0) } values %{$runner->{assigned} // {}}) {
            $run_status->{assigned} += $job->{count};
            my $stamp = $job->{started};
            my $slots = $job->{count};

            push @{$job_table->{rows}} => [$time - $stamp, $slots, $job->{file} // $job->{job_id}];
        }

        $run_status->{pending} = $run_status->{allotted} - $run_status->{assigned};

        $global_status->{$_} += $run_status->{$_} for keys %$global_status;

        my $run_table = {
            header => [qw/Todo Allotted Assigned Pending/],
            rows   => [[$run_status->{todo}, $run_status->{allotted}, $run_status->{assigned}, $run_status->{pending}]],
        };

        push @groups => {
            title  => join(' - ', grep { defined $_ } $runner->{user}, $runner->{name}, $runner->{runner_id}),
            tables => [
                $run_table,
                $job_table,
            ],
        };
    }

    my $total = $self->{+CONFIG}->max_slots;
    $global_status->{total} = $total;
    $global_status->{free}  = $total - ($global_status->{assigned} + $global_status->{pending});
    $global_status->{free}  = "$global_status->{free} (Minimum per-run overrides max slot count in some cases)"
        if $global_status->{free} < 0;

    unshift @groups => {
        title  => 'System Wide Summary',
        tables => [
            {
                header => ['Todo', 'Total Shared Slots', 'Allotted Shared Slots', 'Assigned Shared Slots', 'Pending Shared Slots', 'Free Shared Slots'],
                rows   => [[@{$global_status}{qw/todo total allotted assigned pending free/}]],
            },
        ],
    };

    return \@groups;
}

sub teardown {
    my $self = shift;

    # Best-effort: drop our runner registration so other concurrent
    # yath invocations see us leave promptly. If the state file is
    # unreachable (unmounted NFS, missing permissions after a config
    # change, etc.) we swallow the error -- the TIMEOUT heartbeat
    # will eventually clear us anyway.
    return if $self->{+OBSERVE};

    my $state = $self->{+STATE} or return;

    unless (eval { $state->remove_registration; 1 }) {
        my $err = $@;
        warn "SharedJobSlots: teardown failed to remove_registration: $err";
    }

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Resource::SharedJobSlots - Cross-project job-slot
coordination resource.

=head1 DESCRIPTION

Coordinates test-job slots across multiple concurrent yath
invocations on the same host. Every participating runner (different
checkouts, different users, different CI workers on the same
machine) shares a slot pool by reading and writing a common state
file protected by L<Fcntl/flock>.

In the new harness topology (see C<IPC_AND_LOGGERS> section 9), this
is an B<in-process> resource: it consumes
L<Test2::Harness2::Role::Resource> directly, lives in the harness
service's memory, and coordinates across independent yath processes
via the shared JSON state file rather than through the IPC bus. No
C<service_*_start> method is declared; every yath invocation
instantiates its own copy of the resource and those copies agree by
writing to the same file under a mutual exclusion lock.

See L</DISCOVERY AND COORDINATION MEDIUM> below for the rationale
on why this resource is file-coordinated rather than socket- or
bus-coordinated.

=head1 CONFIG FILE

See L<App::Yath2::Resource::SharedJobSlots::Config> for the full
config-file shape. Briefly:

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

Each host's section specifies at minimum a C<state_file> and a
C<max_slots>; optional keys tune per-run / per-job caps and the
redistribution C<algorithm> (C<fair> / C<first> / a
fully-qualified C<Module::function> custom sort).

The config file can live in the project root as
C<.sharedjobslots.yml> or anywhere on disk with the path passed via
the C<--shared-jobs-config> option; the loader walks up from cwd
looking for a match when given a bare filename.

=head1 ATTRIBUTES

=over 4

=item slots

Required positive integer. The local cap on slots this runner will
use. The actual number of slots granted at any moment is the
minimum of this value and the config's C<max_slots>.

=item job_slots

Positive integer. Default C<1>. Per-job cap the same way C<slots>
is a per-runner cap. Combined with the test file's own
C<min_slots> / C<max_slots> declaration via
L<Test2::Harness2::Role::TestFile>.

=item shared_jobs_config

Path to the config file or a bare filename to search for. Defaults
to C<.sharedjobslots.yml>.

=item host

Override the hostname used to select the per-host config section.
Defaults to L<Sys::Hostname/hostname>.

=item project

Runner-registration project name. Defaults to the basename of
C<cwd>. Used purely for display ("SystemWideSummary" rows).

=item cwd

Working directory used to derive a default project name when
C<project> is not provided. Defaults to C<Cwd::getcwd()>.

=item procname_prefix

Optional prefix prepended to the project name ("ci-my-project").
Matches old/'s C<harness-E<gt>procname_prefix> behaviour.

=item runner_id

Unique id identifying this runner on the shared state file.
Defaults to C<USER-PROJECT-PID>. Override when two runners in the
same checkout need to look distinct.

=item runner_pid

Pid written into the state-file entry. Defaults to C<$$>.

=item observe

When true, the resource still reads the state file for reporting
but never writes assignments or releases. Useful for diagnostic
tools.

=back

=head1 DISCOVERY AND COORDINATION MEDIUM

The harness spec (C<IPC_AND_LOGGERS> section 9) explicitly allows a
resource to coordinate out-of-process in whatever way its
implementation finds practical. SharedJobSlots uses a shared state
file on disk (plus a sibling C<.LOCK> file for mutual exclusion)
rather than a coordinator service reachable over IPC::Manager for
two reasons:

=over 4

=item 1.

B<Cross-invocation is the point.> Two independent yath invocations
on the same host must share the slot pool. Neither one owns the
coordinator; having a third "shared" process that both talk to via
IPC::Manager would require a well-known rendezvous point anyway
(socket path, PID file) that both yaths can find. A YAML config
pointing at a state-file path is the simplest working rendezvous
for that and matches the old/ and legacy behaviour users expect.

=item 2.

B<No service methods implies no service subprocess.> Per the
resource contract (C<IPC_AND_LOGGERS> section 9.1), a resource
with zero C<service_*_start> methods needs no supervisor. Running
the coordination logic inline in each yath keeps the resource
hierarchy flat and avoids introducing a new "shared coordinator"
service type.

A future revision may add an optional C<service_sharedjobslots_start>
method to let an individual host promote the co-ordinator into a
long-lived per-host service; the file-coordinated path stays
authoritative in its absence.

=back

=head1 RESOURCE HOOKS

C<available>, C<assign>, and C<release> delegate to
L<App::Yath2::Resource::SharedJobSlots::State>, which owns the
flock-protected transaction logic. C<available> returns C<-1> when
the per-test declared minimum exceeds every cap in play (no amount
of redistribution will satisfy it); otherwise it asks the state
machine for an allocation and returns whatever it grants (0 =
try-again, positive = slot count).

C<refresh> updates this runner's heartbeat so other runners see us
as alive (timeout after 5 minutes of silence -- see
L<App::Yath2::Resource::SharedJobSlots::State/TIMEOUT>).

C<teardown> attempts to remove our registration so the state file
reflects reality immediately when this harness shuts down.

=head1 SEE ALSO

L<App::Yath2::Resource::SharedJobSlots::Config>,
L<App::Yath2::Resource::SharedJobSlots::State>,
L<Test2::Harness2::Role::Resource>.

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
