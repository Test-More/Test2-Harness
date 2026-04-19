package Test2::Harness2::Role::ResourceServiceHost;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Time::HiRes qw/time/;

use Role::Tiny;

# Basic restart-spiral protection for resource services. A service that
# survives RESTART_HEALTHY_SECS resets its attempts counter back to 1 on
# its next exit; consecutive fast-exits accumulate and the resource flips
# to permanent_broken after MAX_RESTART_ATTEMPTS.
use constant MAX_RESTART_ATTEMPTS => 5;
use constant RESTART_HEALTHY_SECS => 30;

# Consumer contract: an accessor that returns the working directory the
# host is writing logs under, an accessor for the host's own service
# name (reserved in its scope), and a hash slot that stores tracked
# services keyed by pid.
requires 'workdir';
requires 'name';

# The scope the host itself occupies. Defaults to 'global' for the
# harness. Run-scoped hosts override to 'run'.
sub _service_host_scope { 'global' }

# The run object this host is bound to, when the host is run-scoped.
# Global hosts return undef.
sub _service_host_run { undef }

# The tracking hashref for resource services (pid => entry). Consumers
# expose this via a HashBase attribute called resource_services; the
# role reads/writes through this method so a consumer can override the
# storage if it needs to.
sub resource_services {
    my $self = shift;
    $self->{resource_services} //= {};
    return $self->{resource_services};
}

sub _start_resource_services {
    my ($self, $resources, %opts) = @_;

    my $scope = $opts{scope} // 'global';
    my $run   = $opts{run};

    # Walk the resources once to derive service names and validate
    # uniqueness BEFORE invoking any service_* method. We never want to
    # fork a subprocess only to discover its log file would collide with
    # another service's. Build the ordered start list here and hand it to
    # _invoke_service_method one entry at a time.
    my @plan;
    my %seen;
    for my $res (@$resources) {
        for my $method ($res->service_methods) {
            my $name = _resource_service_name_from_method($method);

            croak sprintf(
                "resource '%s' service '%s' collides with in-batch service '%s' (name '%s' in %s scope)",
                $res->resource_name,  $method,
                $seen{$name}{method}, $name,
                $scope,
            ) if $seen{$name};

            $self->_assert_service_name_unused(
                name  => $name,
                scope => $scope,
                run   => $run,
                (resource => $res, method => $method),
            );

            my $log_path = $self->_resource_service_log_path(
                name  => $name,
                scope => $scope,
                run   => $run,
            );
            _touch_log_file($log_path);

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

# service_foo -> foo. Consumers could theoretically declare a method
# literally named 'service_' (empty suffix); we refuse that here because
# the resulting empty name would create a bare '.jsonl' file.
sub _resource_service_name_from_method {
    my ($method) = @_;
    (my $name = $method) =~ s/^service_//;
    croak "cannot derive service name from method '$method'"
        unless length $name;
    return $name;
}

sub _resource_service_log_path {
    my ($self, %p) = @_;

    my $name  = $p{name}  // croak "'name' is required";
    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    my $dir = $scope eq 'run'
        ? do {
        croak "run-scoped service log path requires 'run'" unless ref $run;
        my $rid = $run->run_id;
        join '/', $self->workdir, 'runs', $rid, 'services';
        }
        : join '/', $self->workdir, 'services';

    make_path($dir) unless -d $dir;

    return "$dir/$name.jsonl";
}

sub _touch_log_file {
    my ($path) = @_;
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

    my $host_scope = $self->_service_host_scope;
    my $host_run   = $self->_service_host_run;

    my $reserved = $host_scope eq $scope;
    if ($reserved && $host_scope eq 'run') {
        $reserved = ref($host_run) && ref($run) && $host_run == $run;
    }

    if ($reserved && defined $self->name && $self->name eq $name) {
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

        # Same (resource, method) is the restart case -- we'll drop the
        # old entry before re-invoking, so it's not a real collision.
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

# Single source of truth for calling a resource's service_* method. Used
# at initialization (_start_resource_services) and on restart
# (_handle_resource_service_exit).
#
# Returns the method's return value (or undef if the method died). The
# caller is responsible for acting on the return: -1 / undef means no
# new tracking state should exist; >= 0 means the resource should have
# called track_resource_service from inside the method to hand over the
# pid.
#
# Enforces the POD contract that the restart flag on any newly-tracked
# service entry is the return value of the method, not the named
# argument the author happened to pass.
sub _invoke_service_method {
    my ($self, $res, $method, %opts) = @_;

    my $scope = $opts{scope} // 'global';
    my $run   = $opts{run};

    # Resolve and prepare the service's name + log path, defaulting to
    # the method-derived name and the path under workdir. The caller
    # (_start_resource_services or restart) may pass them pre-computed
    # to avoid a redundant make_path/touch.
    my $name     = $opts{name}     // _resource_service_name_from_method($method);
    my $log_path = $opts{log_path} // do {
        my $p = $self->_resource_service_log_path(
            name  => $name,
            scope => $scope,
            run   => $run,
        );
        _touch_log_file($p);
        $p;
    };

    # Snapshot pre-existing tracked pids for this (resource, method) pair
    # BEFORE the method runs. Any tracked entry that existed before the
    # call had its restart flag set by a previous invocation; the flag
    # rewrite below applies only to entries that appeared during this
    # call, so we never clobber a sibling pid that's still running under
    # the same method name.
    my $services = $self->resource_services;
    my %pre_existing =
        map { $_->{pid} => 1 }
        grep { $_->{resource} == $res && defined $_->{method} && $_->{method} eq $method } values %$services;

    my $status;
    my $ok = eval {
        $status = $res->$method(
            harness  => $self,
            scope    => $scope,
            name     => $name,
            log_path => $log_path,
            (defined $run ? (run => $run) : ()),
        );
        1;
    };
    my $err = $@;
    unless ($ok) {
        warn "resource '" . $res->resource_name . "' service '$method' died: $err";
        return undef;
    }

    return $status if !defined($status) || $status < 0;

    # Service started. Enforce the POD contract on newly-tracked entries:
    # the restart flag is the return value of the method, not whatever
    # named argument the author happened to pass to track_resource_service.
    # Stamp the resolved name + log_path on any entry that didn't get
    # them explicitly from the resource; this keeps later status reports
    # and restart paths coherent even when a resource author forgot to
    # echo those arguments back.
    for my $svc (values %$services) {
        next unless $svc->{resource} == $res;
        next unless defined $svc->{method} && $svc->{method} eq $method;
        next if $pre_existing{$svc->{pid}};
        $svc->{restart} = $status ? 1 : 0;
        $svc->{name}     //= $name;
        $svc->{log_path} //= $log_path;
    }

    return $status;
}

sub track_resource_service {
    my ($self, %p) = @_;

    my $pid = $p{pid}      or croak "'pid' is required";
    my $res = $p{resource} or croak "'resource' is required";

    my $scope = $p{scope} // 'global';
    my $run   = $p{run};

    # Derive the service's public name either from the caller's argument
    # or from the method name (service_foo -> foo). Every tracked entry
    # is expected to carry a name; the name maps 1:1 to a log file path.
    my $name = $p{name};
    if (!defined $name && defined $p{method}) {
        $name = _resource_service_name_from_method($p{method});
    }
    croak "cannot track a resource service without a 'name' (and no 'method' to derive one from)"
        unless defined $name && length $name;

    # Last-resort name-uniqueness check. _start_resource_services does
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
    _touch_log_file($log_path);

    # NOTE: the caller may seed {restart} here, but the authoritative value
    # is set by _invoke_service_method based on the service method's
    # return code (0 vs 1). This keeps the POD contract enforced in one
    # place rather than trusting each resource author.
    $self->resource_services->{$pid} = {
        pid        => $pid,
        resource   => $res,
        method     => $p{method},
        name       => $name,
        log_path   => $log_path,
        scope      => $scope,
        restart    => $p{restart} ? 1 : 0,
        started_at => $p{started_at} // time,
        attempts   => $p{attempts}   // 1,
        (defined $run ? (run => $run) : ()),
    };

    return $pid;
}

# Called from the consumer's run_on_pid when a pid that isn't something
# else (test collector, worker, ...) has exited. Returns 1 if the pid
# belonged to a tracked resource service (handled here); 0 if it's not
# one of ours and the caller should handle it (or ignore it).
sub _handle_resource_service_exit {
    my ($self, $pid, $exit) = @_;

    my $services = $self->resource_services;

    # Drop the tracking entry first so the restart branch below (which
    # may cause the resource's service_* method to register a new pid)
    # cannot collide with the old one.
    my $svc = delete $services->{$pid} or return 0;

    my $res    = $svc->{resource};
    my $method = $svc->{method};

    # Non-restartable service: the resource is effectively gone for the
    # rest of this host's lifetime.
    unless ($svc->{restart}) {
        $res->mark_permanent_broken;
        return 1;
    }

    # Restartable service: mark broken, then attempt to re-invoke the
    # service_* method. The resource's method is expected to fork a
    # replacement and call track_resource_service with the new pid.
    $res->mark_broken;

    # Basic restart-spiral protection. A service that survived at least
    # RESTART_HEALTHY_SECS resets the attempts counter; otherwise the
    # counter climbs and we eventually give up.
    my $ran_for  = time - ($svc->{started_at} // time);
    my $attempts = ($ran_for >= RESTART_HEALTHY_SECS) ? 1 : (($svc->{attempts} // 1) + 1);

    if ($attempts > MAX_RESTART_ATTEMPTS) {
        warn sprintf(
            "resource '%s' (class %s, last pid %d) service '%s' exceeded %d restart attempts; marking permanent_broken\n",
            $res->resource_name, ref($res), $pid, $method, MAX_RESTART_ATTEMPTS,
        );
        $res->mark_permanent_broken;
        return 1;
    }

    # Snapshot existing tracked pids for this (resource, method) so we
    # can identify the new one afterwards and stamp the attempts counter
    # on it.
    my %old_pids = map { $_->{pid} => 1 }
        grep { $_->{resource} == $res && defined $_->{method} && $_->{method} eq $method } values %$services;

    my $status = $self->_invoke_service_method(
        $res, $method,
        scope => $svc->{scope},
        (defined $svc->{name}     ? (name     => $svc->{name})     : ()),
        (defined $svc->{log_path} ? (log_path => $svc->{log_path}) : ()),
        (defined $svc->{run}      ? (run      => $svc->{run})      : ()),
    );

    # Method died: already warned inside the helper. Resource stays marked
    # broken; operator intervention needed.
    return 1 unless defined $status;

    # Method declared the service no longer needed. Treat as permanent:
    # the resource will not come back this session.
    if ($status < 0) {
        $res->mark_permanent_broken;
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
pids, enforce name uniqueness, handle service exits and restarts, and
compute log-file paths. This role consolidates all of that so the two
consumers can't drift.

The role is storage-agnostic: it reads and writes tracking state
through the C<resource_services> accessor and uses the consumer's
C<workdir> / C<name> accessors for path and reservation decisions.

=head1 REQUIRED METHODS

Consumers must provide:

=over 4

=item workdir

Path to the workdir under which log files live.

=item name

The host's own service name (reserved in its scope).

=back

=head1 PROVIDED METHODS

=over 4

=item _service_host_scope

Default C<'global'>. Override to C<'run'> for run-scoped hosts.

=item _service_host_run

Default C<undef>. Override on run-scoped hosts to return the Run object
the host is bound to.

=item resource_services

Returns the tracking hashref (pid =E<gt> entry). Lazy-initialised.

=item _start_resource_services(\@resources, scope =E<gt> ..., run =E<gt> ...)

Validate name uniqueness across the batch and invoke each resource's
C<service_*> methods.

=item track_resource_service(pid =E<gt> ..., resource =E<gt> ..., method =E<gt> ..., ...)

Record a freshly-spawned service pid. Validates name uniqueness and
creates the log file if it doesn't exist yet.

=item _handle_resource_service_exit($pid, $exit)

Called from the consumer's C<run_on_pid> for any pid that wasn't a
collector or worker. Returns true if the pid was one of ours
(restart handled; resource flagged), false if it wasn't.

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
