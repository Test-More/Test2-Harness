package Test2::Harness2::Role::ResourceServiceHost;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Time::HiRes qw/time/;

use Role::Tiny;

# Consumer contract: host-identity accessors, an emit hook (satisfied
# by Role::Service's emit_service_event) so this role can log
# resource-service lifecycle events through the host's event stream,
# the resource_services tracking accessor (see below for its
# contract), and the three host-scope accessors (scope / run / logdir)
# that drive log-file placement and reservation checks.
requires 'workdir';
requires 'name';
requires 'emit_service_event';
requires 'resource_services';

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

sub start_resource_services {
    my ($self, $resources, %opts) = @_;

    my $scope = $opts{scope} // 'global';
    my $run   = $opts{run};

    # Walk the resources once to derive service names and validate
    # uniqueness BEFORE invoking any service_* method. We never want to
    # fork a subprocess only to discover its log file would collide
    # with another service's. Build the ordered start list here and
    # hand it to invoke_service_method one entry at a time.
    my @plan;
    my %seen;
    for my $res (@$resources) {
        for my $method ($res->service_methods) {
            my $name = $self->_resource_service_name_from_method($method);

            if (my $prev = $seen{$name}) {
                croak sprintf(
                    "resource '%s' service '%s' collides with in-batch service '%s' (name '%s' in %s scope)",
                    $res->resource_name, $method,
                    $prev->{resource}->resource_name . "::" . $prev->{method},
                    $name, $scope,
                );
            }

            $self->_assert_service_name_unused(
                name     => $name,
                scope    => $scope,
                run      => $run,
                resource => $res,
                method   => $method,
            );

            my $log_path = $self->_resource_service_log_path(
                name  => $name,
                scope => $scope,
                run   => $run,
            );
            $self->_touch_log_file($log_path);

            $seen{$name} = {resource => $res, method => $method};
            push @plan => {
                resource => $res,
                method   => $method,
                name     => $name,
                log_path => $log_path,
            };
        }
    }

    for my $entry (@plan) {
        $self->_invoke_service_method(
            $entry->{resource}, $entry->{method},
            name     => $entry->{name},
            log_path => $entry->{log_path},
            scope    => $scope,
            (defined $run ? (run => $run) : ()),
        );
    }

    return;
}

# service_foo_start -> foo. A method that does not match the
# service_*_start shape is refused: the service-method discovery path
# only exposes methods matching it, and callers that name a method
# explicitly must still respect the contract.
sub _resource_service_name_from_method {
    my ($self, $method) = @_;

    croak "cannot derive service name from method '$method'"
        unless $method =~ m/^service_(.+)_start\z/;

    return $1;
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

        # Same (resource, method) is the restart case -- we'll drop
        # the old entry before re-invoking, so it's not a real
        # collision.
        next
            if defined $p{resource}
            && defined $p{method}
            && $svc->{resource} == $p{resource}
            && ($svc->{method} // '') eq $p{method};

        croak sprintf(
            "service name '%s' is already in use in %s scope%s",
            $name,
            $scope,
            ($scope eq 'run' ? ' for this run' : ''),
        );
    }

    return;
}

# Single source of truth for calling a resource's service_* method.
# Used at initialization (start_resource_services) and on restart
# (handle_resource_service_exit).
#
# Contract (new as of the service-contract refactor):
#   * If a service_XXX_applicable companion exists and returns false,
#     the service is skipped entirely (no tracking, no brokenness).
#   * The method's return value is ignored. A clean return means the
#     service started; a thrown exception means it failed to start.
#     On exception, the resource is flipped to permanent_broken, a
#     resource_service_start_failed event is emitted through the host's
#     event stream, and the scheduler continues to the next service
#     rather than aborting the whole startup.
sub _invoke_service_method {
    my ($self, $res, $method, %opts) = @_;

    my $scope = $opts{scope} // 'global';
    my $run   = $opts{run};

    # Resolve and prepare the service's name + log path, defaulting to
    # the method-derived name and the path under the host's logdir.
    # The caller (start_resource_services or the restart branch) may
    # pass them pre-computed to avoid a redundant make_path/touch.
    my $name     = $opts{name}     // $self->_resource_service_name_from_method($method);
    my $log_path = $opts{log_path} // do {
        my $p = $self->_resource_service_log_path(
            name  => $name,
            scope => $scope,
            run   => $run,
        );
        $self->_touch_log_file($p);
        $p;
    };

    my %call_args = (
        harness  => $self,
        scope    => $scope,
        name     => $name,
        log_path => $log_path,
        (defined $run ? (run => $run) : ()),
    );

    # Applicability gate. If the resource declared an applicable
    # companion and it returns false, the service is not needed in
    # this environment; skip with no side effects. Companion names
    # drop the '_start' suffix: service_foo_start's companion is
    # service_foo_applicable, not service_foo_start_applicable.
    my $applicable_method = "service_${name}_applicable";
    if ($res->can($applicable_method)) {
        return 'skipped' unless $res->$applicable_method(%call_args);
    }

    my $ok = eval {
        $res->$method(%call_args);
        1;
    };
    my $err = $@;
    unless ($ok) {
        # Propagate the failure through the host's event stream and
        # flip the resource to permanent_broken. Per contract, the
        # exception is not re-thrown: the next service in the batch
        # gets its chance to start, and the resource's own broken
        # state records the failure for scheduling decisions.
        if ($res->can('mark_permanent_broken')) {
            my $mark_ok = eval { $res->mark_permanent_broken; 1 };
            warn "mark_permanent_broken failed on '" . $res->resource_name . "': $@"
                unless $mark_ok;
        }

        $self->emit_service_event(
            kind     => 'resource_service_start_failed',
            resource => $res->resource_name,
            method   => $method,
            name     => $name,
            scope    => $scope,
            error    => "$err",
            (defined $run ? (run_id => $run->run_id) : ()),
        );

        return 'failed';
    }

    # Service started. Stamp the resolved name + log_path onto any
    # tracked entry that was registered during the call but didn't get
    # them explicitly -- this keeps later status reports and restart
    # paths coherent.
    my $services = $self->resource_services;
    for my $svc (values %$services) {
        next unless $svc->{resource} == $res;
        next unless defined $svc->{method} && $svc->{method} eq $method;
        $svc->{name}     //= $name;
        $svc->{log_path} //= $log_path;
    }

    return 'started';
}

# Whether a given (resource, method) pair should be auto-restarted on
# exit. Consults only the optional service_XXX_restartable companion
# (note: the companion drops the '_start' suffix that the starter
# carries); absence means non-restartable. permanent_broken on the
# resource still blocks restart regardless.
sub _service_is_restartable {
    my ($self, $res, $method, %call_args) = @_;
    my $name      = $self->_resource_service_name_from_method($method);
    my $companion = "service_${name}_restartable";
    return 0 unless $res->can($companion);
    return $res->$companion(%call_args) ? 1 : 0;
}

sub track_resource_service {
    my ($self, %p) = @_;

    my $pid = $p{pid}      or croak "'pid' is required";
    my $res = $p{resource} or croak "'resource' is required";

    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    # Derive the service's public name either from the caller's
    # argument or from the method name (service_foo_start -> foo).
    # Every tracked entry is expected to carry a name; the name maps
    # 1:1 to a log file path.
    my $name = $p{name};
    if (!defined $name && defined $p{method}) {
        $name = $self->_resource_service_name_from_method($p{method});
    }
    croak "cannot track a resource service without a 'name' (and no 'method' to derive one from)"
        unless defined $name && length $name;

    # Last-resort name-uniqueness check. start_resource_services does
    # the same validation pre-invoke, but a resource author who calls
    # us directly (bypassing the service_* discovery path) still has to
    # play by the same rules.
    $self->_assert_service_name_unused(
        name     => $name,
        scope    => $scope,
        run      => $run,
        resource => $res,
        (defined $p{method} ? (method => $p{method}) : ()),
    );

    my $log_path = $p{log_path} // $self->_resource_service_log_path(
        name  => $name,
        scope => $scope,
        run   => $run,
    );
    $self->_touch_log_file($log_path);

    # Restartability is NOT stored on the entry: it is looked up
    # lazily from the resource's service_XXX_restartable companion
    # at exit time. That avoids stale flags when a consumer flips
    # the resource's restart posture while a service is already
    # running; it also keeps restart posture in exactly one place.
    $self->resource_services->{$pid} = {
        pid        => $pid,
        resource   => $res,
        method     => $p{method},
        name       => $name,
        log_path   => $log_path,
        scope      => $scope,
        started_at => $p{started_at} // time,
        attempts   => $p{attempts}   // 1,
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
    # (which may cause the resource's service_* method to register a
    # new pid) cannot collide with the old one.
    my $svc = delete $services->{$pid} or return 0;

    my $res    = $svc->{resource};
    my $method = $svc->{method};
    my $scope  = $svc->{scope} // 'global';
    my $run    = $svc->{run};

    my %call_args = (
        harness  => $self,
        scope    => $scope,
        name     => $svc->{name},
        log_path => $svc->{log_path},
        (defined $run ? (run => $run) : ()),
    );

    my $restartable =
        defined $method
        ? $self->_service_is_restartable($res, $method, %call_args)
        : 0;

    # Non-restartable service: the resource is effectively gone for
    # the rest of this host's lifetime.
    unless ($restartable) {
        $res->mark_permanent_broken if $res->can('mark_permanent_broken');
        return 1;
    }

    # Restartable service: mark broken, then attempt to re-invoke the
    # service_* method. The resource's method is expected to fork a
    # replacement and call track_resource_service with the new pid.
    $res->mark_broken if $res->can('mark_broken');

    # Basic restart-spiral protection. A service that survived at
    # least restart_healthy_secs() resets the attempts counter;
    # otherwise the counter climbs and we eventually give up.
    my $healthy_secs = $self->restart_healthy_secs;
    my $max_attempts = $self->max_restart_attempts;
    my $ran_for  = time - ($svc->{started_at} // time);
    my $attempts = ($ran_for >= $healthy_secs) ? 1 : (($svc->{attempts} // 1) + 1);

    if ($attempts > $max_attempts) {
        warn sprintf(
            "resource '%s' (class %s, last pid %d) service '%s' exceeded %d restart attempts; marking permanent_broken\n",
            $res->resource_name, ref($res), $pid, $method, $max_attempts,
        );
        $res->mark_permanent_broken if $res->can('mark_permanent_broken');
        return 1;
    }

    # Snapshot existing tracked pids for this (resource, method) so
    # we can identify the new one afterwards and stamp the attempts
    # counter on it.
    my %old_pids = map { $_->{pid} => 1 }
        grep { $_->{resource} == $res && defined $_->{method} && $_->{method} eq $method } values %$services;

    my $outcome = $self->_invoke_service_method(
        $res, $method,
        scope => $scope,
        (defined $svc->{name}     ? (name     => $svc->{name})     : ()),
        (defined $svc->{log_path} ? (log_path => $svc->{log_path}) : ()),
        (defined $run             ? (run      => $run)             : ()),
    );

    # Start failed. _invoke_service_method already marked the
    # resource permanent_broken and emitted the failure event.
    return 1 if $outcome eq 'failed';

    # Resource declared the service no longer applicable. Treat as
    # permanent: the resource will not come back this session.
    if ($outcome eq 'skipped') {
        $res->mark_permanent_broken if $res->can('mark_permanent_broken');
        return 1;
    }

    # New pid (or pids) registered. Apply the attempts counter so the
    # next exit knows how many tries we've already spent.
    for my $new_svc (values %$services) {
        next unless $new_svc->{resource} == $res;
        next unless defined $new_svc->{method} && $new_svc->{method} eq $method;
        next if $old_pids{$new_svc->{pid}};
        $new_svc->{attempts} = $attempts;
    }

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
invoke C<service_*> methods on their resources, track the resulting
pids, enforce name uniqueness, handle service exits (including
restarts), and compute log-file paths. This role consolidates all of
that so the two consumers can't drift.

The role is storage-agnostic: it reads and writes tracking state
through the C<resource_services> accessor and uses the consumer's
C<workdir> / C<name> / C<emit_service_event> methods (the last of
which Role::Service already provides) for path decisions, reservation
checks, and failure logging.

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
C<method>, C<name>, C<log_path>, C<scope>, C<started_at>, and
C<attempts> (plus C<run> for per-run scope); see L</track_resource_service>.

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

Walk each resource's C<service_methods>, validate name uniqueness
across the batch, invoke each service method, and track the resulting
pids. Skipped services (C<service_XXX_applicable> returned false) and
failed services (service method threw) are each handled inline; the
loop continues to the next service after either outcome.

=item $host->track_resource_service(pid => ..., resource => ..., method => ..., ...)

Record a freshly-spawned service pid. Validates name uniqueness,
creates the log file if it does not exist yet, and stores a tracking
entry keyed by pid. Restart posture is B<not> stored here -- it is
resolved lazily at exit time via the resource's
C<service_XXX_restartable> companion (no companion means
non-restartable).

=item $bool = $host->handle_resource_service_exit($pid, $exit)

Called from the consumer's C<run_on_pid> for any pid that wasn't a
collector or worker. Returns true when the pid belonged to a tracked
resource service (restart handled; resource flagged), false when it
was something else.

=back

=head1 SERVICE-METHOD CONTRACT

See L<Test2::Harness2::Role::Resource/SERVICE METHODS> for the full
contract. Briefly:

=over 4

=item *

C<service_XXX_applicable> (if defined) is consulted before any start
attempt. Returning false skips the service entirely.

=item *

C<service_XXX> starts the service. The return value is ignored.
Success is signalled by returning normally; failure is signalled by
throwing. On throw the resource is flipped to C<permanent_broken> and
a C<resource_service_start_failed> event is emitted through the host's
event stream.

=item *

Restartability is read only from C<service_XXX_restartable>; absence
means the service is not restarted. A restartable service that
exits triggers a re-invocation of the service method, subject to
the C<max_restart_attempts> / C<restart_healthy_secs>
spiral-protection accessors (see L</PROVIDED METHODS>).

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
