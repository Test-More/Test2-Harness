package Test2::Harness2::Role::ResourceServiceHost;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use IPC::Manager qw/ipcm_service/;

use Role::Tiny;

use Test2::Harness2::Util qw/load_module/;

# Consumer contract: host-identity accessors, an emit hook (satisfied
# by Role::Service's emit_service_event) so this role can log
# resource-service lifecycle events through the host's event stream,
# the resource_services tracking accessor (see below for its
# contract), the three host-scope accessors (scope / run / logdir)
# that drive log-file placement and reservation checks, and
# ipcm_info (supplied by IPC::Manager::Role::Service) so the host can
# pass its IPC bus information into each service instance.
requires 'workdir';
requires 'name';
requires 'emit_service_event';
requires 'resource_services';
requires 'ipcm_info';

# The scope the host itself occupies. 'global' for the harness,
# 'run' for the run service. No default: consumers must be explicit
# about what scope their host occupies.
requires 'service_host_scope';

# The run object this host is bound to when service_host_scope is
# 'run'. Must return undef for 'global' hosts. No default.
requires 'service_host_run';

# The directory root under which this host lays out service log
# files. Both scope=global ('services/<name>.jsonl') and scope=run
# ('runs/<run_id>/services/<name>.jsonl') paths hang off this root.
# No default: every host picks an explicit root (typically
# $workdir/logs/).
requires 'service_host_logdir';

# The name the host uses for its own log file (and which a resource
# service cannot take in the host's scope). Defaults to the bus-level
# name; consumers whose bus name differs from their log file name
# (e.g. RunService, where the bus name has to be unique per run but
# the log file is just "run.jsonl") override this.
sub service_host_log_name { $_[0]->name }

# Basic restart-spiral protection for resource services. A service
# that survives restart_healthy_secs() resets its attempts counter
# back to 1 on its next exit; consecutive fast-exits accumulate and
# the resource flips to permanent_broken after
# max_restart_attempts() tries. Both accessors are overridable with
# sensible defaults.
sub max_restart_attempts { 5 }
sub restart_healthy_secs { 30 }

use constant SERVICE_ROLE => 'Test2::Harness2::Role::ResourceService';

sub start_resource_services {
    my ($self, $resources, %opts) = @_;

    my $scope = $opts{scope} // 'global';
    my $run   = $opts{run};

    # Walk the resources once to build the full plan (class +
    # construction params + derived name + log_path), validating that
    # every service class composes the service role and that every
    # name is unique within this scope. We never want to fork a
    # subprocess only to discover another in the batch would collide
    # with it.
    my @plan;
    my %seen;
    for my $res (@$resources) {
        for my $entry ($res->services) {
            croak sprintf(
                "resource '%s' services() entry is not an arrayref",
                $res->resource_name,
            ) unless ref($entry) eq 'ARRAY';

            my ($class, @args) = @$entry;
            croak sprintf(
                "resource '%s' services() entry is missing a service class",
                $res->resource_name,
            ) unless defined $class && length $class && !ref $class;

            load_module($class);
            croak sprintf(
                "resource '%s' service class '%s' does not consume %s",
                $res->resource_name, $class, SERVICE_ROLE,
            ) unless Role::Tiny::does_role($class, SERVICE_ROLE);

            my $name = _extract_name(\@args);
            croak sprintf(
                "resource '%s' service '%s' entry is missing a 'name' construction parameter",
                $res->resource_name, $class,
            ) unless defined $name && length $name;

            if (my $prev = $seen{$name}) {
                croak sprintf(
                    "resource '%s' service '%s' collides with in-batch service '%s' (name '%s' in %s scope)",
                    $res->resource_name, $class,
                    $prev->{resource}->resource_name . "::" . $prev->{class},
                    $name, $scope,
                );
            }

            $self->_assert_service_name_unused(
                name     => $name,
                scope    => $scope,
                run      => $run,
                resource => $res,
                class    => $class,
            );

            my $log_path = $self->_resource_service_log_path(
                name  => $name,
                scope => $scope,
                run   => $run,
            );
            $self->_touch_log_file($log_path);

            $seen{$name} = {resource => $res, class => $class};
            push @plan => {
                resource => $res,
                class    => $class,
                args     => \@args,
                name     => $name,
                log_path => $log_path,
            };
        }
    }

    for my $entry (@plan) {
        $self->_start_service_entry(
            resource => $entry->{resource},
            class    => $entry->{class},
            args     => $entry->{args},
            name     => $entry->{name},
            log_path => $entry->{log_path},
            scope    => $scope,
            (defined $run ? (run => $run) : ()),
        );
    }

    return;
}

# Pull the 'name' value out of a key/value construction-params list
# without consuming the list (services() returns may be shared across
# calls). Returns undef if no 'name' pair is present.
sub _extract_name {
    my ($args) = @_;
    my $n = @$args;
    for (my $i = 0; $i + 1 < $n; $i += 2) {
        my $k = $args->[$i];
        next                   if ref $k;
        return $args->[$i + 1] if $k eq 'name';
    }
    return undef;
}

sub _resource_service_log_path {
    my ($self, %p) = @_;

    my $name  = $p{name}  // croak "'name' is required";
    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    my $dir;
    if ($scope eq 'run') {
        croak "run-scoped service log path requires 'run'" unless ref $run;
        my $run_id = $run->run_id;
        $dir = join '/', $self->service_host_logdir, 'runs', $run_id, 'services';
    }
    else {
        $dir = join '/', $self->service_host_logdir, 'services';
    }

    make_path($dir) unless -d $dir;

    return "$dir/$name.jsonl";
}

sub _touch_log_file {
    my ($self, $path) = @_;
    return if -e $path;
    open my $fh, '>>', $path or croak "open '$path': $!";
    close $fh;
    return;
}

# Reject a service name that would collide with another service in the
# same scope. The host's own name is reserved in its own scope because
# its logger already owns <scope_dir>/<name>.jsonl.
sub _assert_service_name_unused {
    my ($self, %p) = @_;

    my $name  = $p{name}  // croak "'name' is required";
    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    my $host_scope = $self->service_host_scope;
    my $host_run   = $self->service_host_run;

    my $reserved = $host_scope eq $scope;
    if ($reserved && $host_scope eq 'run') {
        $reserved = ref($host_run) && ref($run) && $host_run == $run;
    }

    my $host_log_name = $self->service_host_log_name;
    if ($reserved && defined $host_log_name && $host_log_name eq $name) {
        croak sprintf(
            "service name '%s' is reserved by the %s service itself",
            $name, $host_scope,
        );
    }

    my $services = $self->resource_services;
    for my $svc (values %$services) {
        my $svc_scope = $svc->{scope} // 'global';
        next unless ($svc->{name} // '') eq $name;
        next unless $svc_scope eq $scope;
        if ($scope eq 'run') {
            next unless ref($svc->{run}) && ref($run) && $svc->{run} == $run;
        }

        # Same (resource, class) is the restart case -- we'll drop
        # the old entry before re-invoking, so it's not a real
        # collision.
        next
            if defined $p{resource}
            && defined $p{class}
            && $svc->{resource} == $p{resource}
            && ($svc->{service_class} // '') eq $p{class};

        croak sprintf(
            "service name '%s' is already in use in %s scope%s",
            $name,
            $scope,
            ($scope eq 'run' ? ' for this run' : ''),
        );
    }

    return;
}

# Single source of truth for constructing, spawning, and tracking one
# resource service entry. Used at initialization
# (start_resource_services) and on restart (handle_resource_service_exit).
#
# Delegates to IPC::Manager's ipcm_service for the actual fork +
# service-loop setup; the handle it returns carries the first-fork pid
# via $handle->child_pid. That's the pid the host tracks and watches
# (it equals the service pid when the service has no post_fork_hook,
# and equals the wrapper pid when the service interposes a collector /
# wrapper via its own post_fork_hook).
#
# On ipcm_service failure (construction throw, missing child_pid,
# ready-timeout croak) the resource is flipped to permanent_broken, a
# resource_service_start_failed event is emitted through the host's
# event stream, and the caller sees 'failed'. A successful spawn
# returns 'started'.
sub _start_service_entry {
    my ($self, %opts) = @_;

    my $res      = $opts{resource} // croak "'resource' is required";
    my $class    = $opts{class}    // croak "'class' is required";
    my $args     = $opts{args}     // [];
    my $name     = $opts{name}     // croak "'name' is required";
    my $log_path = $opts{log_path} // croak "'log_path' is required";
    my $scope    = $opts{scope}    // 'global';
    my $run      = $opts{run};

    my $handle;
    my $start_ok = eval {
        $handle = ipcm_service(
            $name,
            class     => $class,
            ipcm_info => $self->ipcm_info,
            log_path  => $log_path,
            @$args,
        );
        1;
    };
    my $start_err = $@;
    unless ($start_ok) {
        $self->_fail_service(
            resource => $res,
            class    => $class,
            name     => $name,
            scope    => $scope,
            run      => $run,
            error    => $start_err,
        );
        return 'failed';
    }

    my $pid = $handle ? $handle->child_pid : undef;
    unless (defined $pid) {
        $self->_fail_service(
            resource => $res,
            class    => $class,
            name     => $name,
            scope    => $scope,
            run      => $run,
            error    => "ipcm_service returned a handle with no child_pid",
        );
        return 'failed';
    }

    $self->track_resource_service(
        pid           => $pid,
        resource      => $res,
        service_class => $class,
        service_args  => [@$args],
        name          => $name,
        log_path      => $log_path,
        scope         => $scope,
        started_at    => $opts{started_at} // time,
        attempts      => $opts{attempts}   // 1,
        (defined $run ? (run => $run) : ()),
    );

    return 'started';
}

sub _fail_service {
    my ($self, %p) = @_;

    my $res   = $p{resource};
    my $class = $p{class};
    my $name  = $p{name};
    my $scope = $p{scope} // 'global';
    my $run   = $p{run};
    my $err   = $p{error};

    if ($res->can('mark_permanent_broken')) {
        my $mark_ok = eval { $res->mark_permanent_broken; 1 };
        warn "mark_permanent_broken failed on '" . $res->resource_name . "': $@"
            unless $mark_ok;
    }

    $self->emit_service_event(
        kind          => 'resource_service_start_failed',
        resource      => $res->resource_name,
        service_class => $class,
        name          => $name,
        scope         => $scope,
        error         => "$err",
        (defined $run ? (run_id => $run->run_id) : ()),
    );

    return;
}

sub track_resource_service {
    my ($self, %p) = @_;

    my $pid = $p{pid}      or croak "'pid' is required";
    my $res = $p{resource} or croak "'resource' is required";

    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    my $class = $p{service_class};
    croak "'service_class' is required" unless defined $class && length $class;

    my $name = $p{name};
    croak "cannot track a resource service without a 'name'"
        unless defined $name && length $name;

    # Last-resort name-uniqueness check. start_resource_services does
    # the same validation pre-spawn, but a caller that bypasses that
    # path still has to play by the same rules.
    $self->_assert_service_name_unused(
        name     => $name,
        scope    => $scope,
        run      => $run,
        resource => $res,
        class    => $class,
    );

    my $log_path = $p{log_path} // $self->_resource_service_log_path(
        name  => $name,
        scope => $scope,
        run   => $run,
    );
    $self->_touch_log_file($log_path);

    # Snapshot restartability from the service class at track time.
    # The class method is the single source of truth; we store the
    # value so handle_resource_service_exit doesn't need to reach back
    # into the class after the service is gone.
    my $restartable = $class->restartable ? 1 : 0;

    $self->resource_services->{$pid} = {
        pid           => $pid,
        resource      => $res,
        service_class => $class,
        service_args  => $p{service_args} // [],
        name          => $name,
        log_path      => $log_path,
        scope         => $scope,
        restartable   => $restartable,
        started_at    => $p{started_at} // time,
        attempts      => $p{attempts}   // 1,
        (defined $run ? (run => $run) : ()),
    };

    return $pid;
}

# Called from the consumer's run_on_pid when a pid that isn't
# something else (test collector, worker, ...) has exited. Returns 1
# if the pid belonged to a tracked resource service (handled here); 0
# if it's not one of ours and the caller should handle it (or ignore
# it).
sub handle_resource_service_exit {
    my ($self, $pid, $exit) = @_;

    my $services = $self->resource_services;

    # Drop the tracking entry first so the restart branch below
    # (which calls _start_service_entry, which may register a new
    # pid) cannot collide with the old one.
    my $svc = delete $services->{$pid} or return 0;

    my $res         = $svc->{resource};
    my $class       = $svc->{service_class};
    my $args        = $svc->{service_args} // [];
    my $name        = $svc->{name};
    my $log_path    = $svc->{log_path};
    my $scope       = $svc->{scope} // 'global';
    my $run         = $svc->{run};
    my $restartable = $svc->{restartable} ? 1 : 0;

    # Non-restartable service: the resource is effectively gone for
    # the rest of this host's lifetime.
    unless ($restartable) {
        $res->mark_permanent_broken if $res->can('mark_permanent_broken');
        return 1;
    }

    # Restartable service: mark broken, then attempt to re-spawn it.
    $res->mark_broken if $res->can('mark_broken');

    # Basic restart-spiral protection. A service that survived at
    # least restart_healthy_secs() resets the attempts counter;
    # otherwise the counter climbs and we eventually give up.
    my $healthy_secs = $self->restart_healthy_secs;
    my $max_attempts = $self->max_restart_attempts;
    my $ran_for      = time - ($svc->{started_at} // time);
    my $attempts     = ($ran_for >= $healthy_secs) ? 1 : (($svc->{attempts} // 1) + 1);

    if ($attempts > $max_attempts) {
        warn sprintf(
            "resource '%s' (class %s, last pid %d) service '%s' exceeded %d restart attempts; marking permanent_broken\n",
            $res->resource_name, ref($res), $pid, $name, $max_attempts,
        );
        $res->mark_permanent_broken if $res->can('mark_permanent_broken');
        return 1;
    }

    my $outcome = $self->_start_service_entry(
        resource => $res,
        class    => $class,
        args     => $args,
        name     => $name,
        log_path => $log_path,
        scope    => $scope,
        attempts => $attempts,
        (defined $run ? (run => $run) : ()),
    );

    # Start failed. _start_service_entry already marked the resource
    # permanent_broken and emitted the failure event.
    return 1 if $outcome eq 'failed';

    return 1;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::ResourceServiceHost - Shared resource-service
hosting logic for L<Test2::Harness2> and L<Test2::Harness2::RunService>.

=head1 DESCRIPTION

Both the global harness service and the per-run run service need to
instantiate and spawn the supervised subprocesses declared by their
resources, track the resulting pids, enforce name uniqueness, handle
service exits (including restarts), and compute log-file paths. This
role consolidates all of that so the two consumers can't drift.

The role is storage-agnostic: it reads and writes tracking state
through the C<resource_services> accessor and uses the consumer's
C<workdir> / C<name> / C<emit_service_event> / C<ipcm_info> methods
(the last two of which L<Test2::Harness2::Role::Service> and
L<IPC::Manager::Role::Service> already provide) for path decisions,
reservation checks, service construction, and failure logging.

=head1 REQUIRED METHODS

Consumers must provide:

=over 4

=item workdir

Path to the working directory under which log files live.

=item name

The host's own service name (reserved in its scope).

=item emit_service_event(%fields)

Emit a structured event through the host's event stream.
L<Test2::Harness2::Role::Service> supplies this; hosts that compose
both roles get it for free.

=item ipcm_info

The host's IPC::Manager bus info. Forwarded into every resource
service instance so each service connects to the same bus as its
host. L<IPC::Manager::Role::Service> supplies this.

=item $hashref = $host->resource_services

Return a mutable hashref that maps pid =E<gt> entry for currently
running resource services. The role reads and writes through this
accessor and expects it to return the same underlying hashref on
every call (so in-place mutation via C<< $services-E<gt>{$pid} = ... >>
and C<delete $services-E<gt>{$pid}> is visible to the next caller).
The hashref must be initialised before the first role-provided method
is invoked; returning a fresh empty hashref per call would strand
tracking state.

A typical C<Object::HashBase>-backed consumer satisfies this with a
read-only accessor over a slot that C<init> primes to C<{}>:

    use constant RESOURCE_SERVICES => 'resource_services';

    use Object::HashBase qw{
        ...
        <resource_services
        ...
    };

    sub init {
        my $self = shift;
        $self->{+RESOURCE_SERVICES} //= {};
        ...
    }

Each tracked entry is a hashref carrying at least C<pid>, C<resource>,
C<service_class>, C<service_args>, C<name>, C<log_path>, C<scope>,
C<restartable>, C<started_at>, and C<attempts> (plus C<run> for
per-run scope); see L</track_resource_service>.

=item $scope = $host->service_host_scope

The scope the host itself occupies: C<'global'> for the harness
service, C<'run'> for the per-run service. No default; consumers
must be explicit.

=item $run = $host->service_host_run

The L<Test2::Harness2::Run> object the host is bound to when
C<service_host_scope> returns C<'run'>, or C<undef> when the scope is
C<'global'>. No default.

=item $path = $host->service_host_logdir

The directory root under which service log files are laid out. Both
C<scope=global> (C<services/E<lt>nameE<gt>.jsonl>) and C<scope=run>
(C<runs/E<lt>run_idE<gt>/services/E<lt>nameE<gt>.jsonl>) paths hang
off this root. No default; consumers typically return
C<< $host->workdir . '/logs' >> or similar.

=back

=head1 PROVIDED METHODS

=over 4

=item $name = $host->service_host_log_name

Default: the host's C<name>. Consumers whose bus name differs from
the log-file name (e.g. C<name => "run-$run_id"> but C<log_name =>
"run">) override this so the reservation check targets the log name,
not the bus name.

=item $n = $host->max_restart_attempts

Maximum number of consecutive fast-exit restart attempts before a
restartable resource service is flipped to C<permanent_broken>.
Default 5. Overridable.

=item $secs = $host->restart_healthy_secs

How long a resource service must have been running before its exit
resets the attempts counter back to 1. Services that survive at
least this long then die are treated as "first restart", not "N+1
in a spiral". Default 30 seconds. Overridable.

=item $host->start_resource_services(\@resources, scope => ..., run => ...)

Walk each resource's C<services> list, validate that each entry names
a class that composes L<Test2::Harness2::Role::ResourceService>,
validate name uniqueness across the batch, and spawn each service via
L<IPC::Manager/ipcm_service>. The pid the host tracks is
C<< $handle->child_pid >> on the handle that C<ipcm_service> returns
-- typically the service pid, or the wrapper pid when the service's
C<post_fork_hook> interposes a collector. A service whose
C<ipcm_service> call throws or whose handle has no C<child_pid> is
flagged individually and the loop continues to the next entry.

=item $host->track_resource_service(pid => ..., resource => ..., service_class => ..., service_args => ..., name => ..., ...)

Record a freshly-spawned service pid. Validates name uniqueness,
creates the log file if it does not exist yet, snapshots the
restartable flag from C<< $service_class->restartable >>, and stores
a tracking entry keyed by pid.

=item $bool = $host->handle_resource_service_exit($pid, $exit)

Called from the consumer's C<run_on_pid> for any pid that wasn't a
collector or worker. Returns true when the pid belonged to a tracked
resource service (restart handled; resource flagged), false when it
was something else.

=back

=head1 SERVICE CONTRACT

See L<Test2::Harness2::Role::Resource/SERVICES> for the full
contract. Briefly:

=over 4

=item *

A resource's C<services> method returns a list of
C<[$class, @construction_params]> entries. Each class must compose
L<Test2::Harness2::Role::ResourceService>.

=item *

C<@construction_params> must contain a C<name =E<gt> $name> pair; the
host adds C<name>, C<log_path>, and C<ipcm_info> when passing the
params through to L<IPC::Manager/ipcm_service> (which in turn passes
them to C<< $class->new >>).

=item *

Restartability comes from C<< $class->restartable >>. Default false.
A restartable service that exits triggers a re-spawn, subject to the
C<max_restart_attempts> / C<restart_healthy_secs> spiral-protection
accessors (see L</PROVIDED METHODS>).

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
