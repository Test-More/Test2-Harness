package Test2::Harness2::Role::Resource;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use mro ();

use Role::Tiny;

requires 'available';
requires 'assign';
requires 'release';
requires 'status';

sub is_job_limiter { 0 }

# Whether this resource applies to a given job. Default: yes.
sub applicable { 1 }

sub resource_name {
    my $self  = shift;
    my $class = ref($self) || $self;
    (my $name = $class) =~ s/^.*:://;
    return lc($name);
}

sub is_broken           { $_[0]->{_resource_broken}    ? 1 : 0 }
sub is_permanent_broken { $_[0]->{_resource_permanent} ? 1 : 0 }
sub is_paused           { $_[0]->{_resource_paused}    ? 1 : 0 }

sub is_usable {
    my $self = shift;
    return 0 if $self->is_broken;
    return 0 if $self->is_permanent_broken;
    return 0 if $self->is_paused;
    return 1;
}

sub mark_broken { $_[0]->{_resource_broken} = 1 }

sub mark_permanent_broken {
    my $self = shift;
    $self->{_resource_permanent} = 1;
    $self->{_resource_broken}    = 1;
}

sub mark_paused { $_[0]->{_resource_paused} = 1 }

sub mark_resumed {
    my $self = shift;
    # Permanent brokenness is sticky: callers should check is_permanent_broken
    # before attempting to resume. We still clear the transient flags so a
    # buggy restart doesn't leave them stuck, but _resource_permanent stays
    # set and is_usable() will still return 0.
    delete $self->{_resource_broken};
    delete $self->{_resource_paused};
}

# Introspect service_* methods declared on the consumer class. Each one is a
# discrete resource-service the harness should try to start. The harness
# interprets the return value:
#   -1 : service not needed, do not start, ignore it
#    0 : service started, do not restart if it exits
#    1 : service started, restart it if it exits before harness shutdown
sub service_methods {
    my $self  = shift;
    my $class = ref($self) || $self;

    my %methods;
    for my $pkg (@{mro::get_linear_isa($class)}) {
        my $stash;
        {
            no strict 'refs';
            $stash = \%{"${pkg}::"};
        }
        for my $name (keys %$stash) {
            next unless $name =~ m/^service_/;
            next if $name eq 'service_methods';    # the introspection helper
            next unless $class->can($name);
            $methods{$name} = 1;
        }
    }

    return sort keys %methods;
}

# Teardown hook; called by the harness when a resource is released globally
# (harness shutdown) or per-run (run completes). Default: no-op.
sub teardown { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Resource - Role for harness resources (job slots,
shared state, memory/disk gating, etc.)

=head1 DESCRIPTION

Resources gate whether a job is allowed to start. The scheduler loop asks
every applicable resource whether it can accommodate a job; if all agree, it
calls C<assign> on each; when the job finishes it calls C<release>. A single
C<is_job_limiter> resource is mandatory for the harness service -- it caps
the total number of concurrent jobs. Without an explicit limiter the harness
falls back to a L<Test2::Harness2::Resource::JobCount> with a single slot.

Resources may also expose one or more C<service_XXX> methods. During
harness initialization (for harness-global resources) or at run start (for
run-scoped resources), the harness invokes each such method and interprets
the return value to decide whether to launch and track a supervised
subprocess on its behalf. See L</SERVICE METHODS> below.

=head1 SYNOPSIS

    package My::Resource;
    use strict;
    use warnings;

    use Object::HashBase qw/<limit <used/;

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub is_job_limiter { 1 }

    sub available {
        my ($self, %p) = @_;
        my $need = $p{need} // 1;
        return 0 if ($self->{+LIMIT} - $self->{+USED}) < $need;
        return $need;
    }

    sub assign  { ... }
    sub release { ... }
    sub status  { ... }

=head1 REQUIRED METHODS

Consumers must implement these. The role applies C<requires> to each.

=over 4

=item $n = $resource->available(%params)

Return value is a three-way signal:

=over 4

=item C<-1>

This resource can never satisfy the request (e.g. the run needs 8 slots but
only 4 exist). The job should be skipped, not deferred.

=item C<0>

Not available right now, try again later. No blocking state should be
implied.

=item C<E<gt> 0>

Resource is available; the integer is the amount granted (for
multi-unit resources this may be less than requested).

=back

C<%params> is free-form and depends on the resource. The scheduler passes
at least C<id> (assignment id) and C<job> (the L<Test2::Harness2::Run::Job>
object); resources may accept additional keys to express richer requests
(e.g. 'need => 2').

=item $resource->assign(%params)

Reserve the resource for a job. Called only after C<available> returned a
positive number. Receives the same C<%params> plus an C<env> hashref the
resource may populate with environment variables that should be exported to
the child process (see L<Test2::Harness2::Resource::JobCount> for an
example).

=item $resource->release(%params)

Release a previously-assigned resource. Receives at least the C<id> passed
to C<assign>.

=item $status = $resource->status

Return a hashref describing the resource's current state (useful for UI
display or the C<resources> status request). Format is resource-specific;
at minimum include enough to show the operator what is assigned and what is
free.

=back

=head1 PROVIDED METHODS

=over 4

=item $bool = $resource->is_job_limiter

Default: false. Resources that cap concurrent job count set this to true.
At least one job limiter must be active in the harness service.

=item $bool = $resource->applicable($id, $job)

Default: true. Override to limit this resource to a subset of jobs.

=item $name = $resource->resource_name

Default: the last component of the class name, lowercased.

=item $bool = $resource->is_broken / is_permanent_broken / is_paused

Return whether the resource is in the corresponding state. A broken or
permanently-broken resource must not be assigned new work. A paused
resource should likewise refuse assignment but may resume later.

=item $bool = $resource->is_usable

True when none of broken / permanent_broken / paused are set.

=item $resource->mark_broken / mark_permanent_broken / mark_paused / mark_resumed

State-transition helpers. C<mark_permanent_broken> also sets broken.
C<mark_resumed> clears transient states but leaves permanent brokenness
intact.

=item @methods = $resource->service_methods

Return the sorted list of C<service_*> method names declared on the
consuming class. Used by the harness to discover and start supervised
subprocesses for this resource. See L</SERVICE METHODS>.

=item $resource->teardown

Called when the resource is being retired (harness shutdown for global
resources, run completion for per-run resources). Default: no-op.

=back

=head1 SERVICE METHODS

A resource may define one or more methods named C<service_SOMETHING>. The
harness introspects these via L</service_methods> at initialization (for
harness-global resources) or at run start (for per-run resources) and
invokes each.

The method is invoked with these keyword arguments:

    harness => $harness,          # the Test2::Harness2 instance
    scope   => 'global' | 'run',  # global init vs per-run startup
    run     => $run,              # only present when scope is 'run'

The method is responsible for deciding whether a service is needed and, if
so, for forking the subprocess and reporting its pid to the harness by
calling:

    $harness->track_resource_service(
        pid      => $pid,
        resource => $self,
        method   => $method_name,
    );

The method then B<returns> a restart-flag integer. The harness uses the
return value (not the pid) as the source of truth for what to do on
service exit:

=over 4

=item C<-1>

The service is not needed in this environment. Do not launch it. Do not
call C<track_resource_service>. The harness will not call the method
again.

=item C<0>

The service has been started (the method already forked and called
C<track_resource_service>). The harness will track the pid, and if it
exits the resource will be marked C<permanent_broken>. The harness will
not automatically restart the service.

=item C<1>

The service has been started and the harness should restart it by calling
the method again if the pid exits before harness shutdown. While the
service is down the resource is considered C<broken> and refuses
assignments; when the service reports readiness (via a C<resource_ready>
or C<resource_resumed> IPC message) the resource becomes usable again.

=back

The harness enforces this contract in C<_invoke_service_method>: after
the method returns, the C<restart> flag on every newly-tracked entry for
this C<(resource, method)> pair is overwritten with the returned code.
A resource author who passes C<< restart =E<gt> 1 >> to C<track_resource_service>
but returns C<0> from the method will have their tracked entry
authoritatively reset to C<restart =E<gt> 0>. Rely on the return value, not
the kwarg.

=head2 Restart semantics

When a restartable (return-value C<1>) service exits, the harness
re-invokes its C<service_*> method. Basic spiral protection caps
consecutive restart attempts at C<MAX_RESTART_ATTEMPTS> (currently 5);
the counter resets to 1 when a service survived at least
C<RESTART_HEALTHY_SECS> (currently 30) before exiting. Note that the
reset is one-shot per long-lived window: a service that survived 30s,
died, and then immediately crash-loops will burn up to
C<MAX_RESTART_ATTEMPTS> rapid retries before the resource is flipped to
C<permanent_broken>. If the re-invoked method dies, the resource stays
C<broken> (no automatic progression to C<permanent_broken>); operator
intervention is required. If the re-invoked method returns C<-1>, the
resource is flipped to C<permanent_broken>.

If a resource is in a broken state while a test is still running against it,
and that test later fails, the test should be queued for re-run (retry
logic is a future concern). If the service is permanently broken, running
tests that depend on it will be failed or skipped according to the run's
policy; the harness will not attempt further restarts.

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
