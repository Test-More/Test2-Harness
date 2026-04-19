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

# Whether this resource participates in a given job's allocation. The
# scheduler checks this first: resources that return 0 are skipped
# entirely for that job (no brokenness check, no assign, no release).
# Default: yes, always needed.
sub needed { 1 }

sub resource_name {
    my $self  = shift;
    my $class = ref($self) || $self;
    (my $name = $class) =~ s/^.*:://;
    return lc($name);
}

# Brokenness / paused state queries. Defaults assume the resource
# cannot enter these states; consumers that can override these
# accessors to read from their own storage. is_usable layers over the
# three.
sub is_broken           { 0 }
sub is_permanent_broken { 0 }
sub is_paused           { 0 }

sub is_usable {
    my $self = shift;
    return 0 if $self->is_broken;
    return 0 if $self->is_permanent_broken;
    return 0 if $self->is_paused;
    return 1;
}

# State-transition hooks. The role can't pick a storage model for the
# consumer, so the defaults croak: calling mark_broken on a resource
# that never declared it could support the transition is a contract
# violation, not a silent no-op. Resources that can be broken/paused
# override these to do their own bookkeeping; resources that cannot
# (e.g. JobCount's broken transitions) leave the croaking defaults in
# place so bad callers fail loudly.
sub mark_broken           { croak ref($_[0]) . "::mark_broken is not implemented" }
sub mark_permanent_broken { croak ref($_[0]) . "::mark_permanent_broken is not implemented" }
sub mark_paused           { croak ref($_[0]) . "::mark_paused is not implemented" }
sub mark_resumed          { croak ref($_[0]) . "::mark_resumed is not implemented" }

# Introspect service_*_start methods declared on the consumer class.
# Each returned method is a discrete resource-service the harness should
# start. Companion methods (service_XXX_applicable,
# service_XXX_restartable) are looked up explicitly by the scheduler
# and do not appear in the list. The _start suffix disambiguates the
# starter from its companions and from any unrelated 'service_*'
# accessor the consumer might define.
sub service_methods {
    my $self  = shift;
    my $class = ref($self) || $self;

    my %seen;
    for my $pkg (@{mro::get_linear_isa($class)}) {
        my $stash;
        {
            no strict 'refs';
            $stash = \%{"${pkg}::"};
        }
        for my $name (keys %$stash) {
            next unless $name =~ m/^service_.+_start\z/;
            next unless $class->can($name);
            $seen{$name} = 1;
        }
    }

    return $self->sort_methods(keys %seen);
}

# Determines the startup order of a resource's services. Default is
# alphabetical by method name; override in a consumer to express
# explicit dependencies (e.g. start the database before the worker
# that reads from it).
sub sort_methods {
    my $self = shift;
    return sort @_;
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

Resources gate whether a job is allowed to start. The scheduler walks
every resource per-job in a fixed order:

=over 4

=item 1. C<needed(job =E<gt> $job)>

If false, the resource is skipped entirely for this job (no brokenness
check, no C<available> call, no C<assign>).

=item 2. C<is_permanent_broken>

If true, the job is marked to be skipped -- no version of this resource
can ever satisfy it.

=item 3. C<is_usable>

If false (resource is transiently broken or paused), the job is
deferred and retried on a later tick.

=item 4. C<available(job =E<gt> $job)>

Only called when the resource is needed AND usable. Returns C<-1> to
skip the job, C<0> to defer, or a positive integer to grant that many
units.

=back

If every needed resource returns a positive grant, the scheduler calls
C<assign> on each; when the job finishes it calls C<release>. A single
C<is_job_limiter> resource is mandatory for the harness service -- it
caps the total number of concurrent jobs. Without an explicit limiter
the harness falls back to a L<Test2::Harness2::Resource::JobCount> with
a single slot.

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

Only called by the scheduler after C<needed> returned true and the
resource is usable (see L</DESCRIPTION>). The implementation does B<not>
need to re-check brokenness or paused state. Return value is a
three-way signal:

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

=item $bool = $resource->needed(job =E<gt> $job)

Default: true. Override to opt this resource out for jobs that do not
need it -- the scheduler then skips every subsequent step
(brokenness/usable/available/assign/release) for that (resource, job)
pair.

=item $name = $resource->resource_name

Default: the last component of the class name, lowercased.

=item $bool = $resource->is_broken / is_permanent_broken / is_paused

Return whether the resource is in the corresponding state. A broken or
permanently-broken resource must not be assigned new work. A paused
resource should likewise refuse assignment but may resume later. The
role's default implementation returns C<0> for all three, so resources
that cannot be broken get a working baseline. Consumers that track
these states override the accessors to read from their own storage.

=item $bool = $resource->is_usable

True when none of broken / permanent_broken / paused are set.

=item $resource->mark_broken / mark_permanent_broken / mark_paused / mark_resumed

State-transition hooks. The role's B<default implementations croak>:
calling mark_broken on a resource that never declared it could support
the transition is a contract violation, not a silent no-op. Resources
that can enter these states override each mark_* they actually support,
and record the transition so the matching C<is_*> accessor starts
returning true. C<mark_permanent_broken> should also flip C<is_broken>
to true; C<mark_resumed> clears transient broken/paused flags but must
leave permanent brokenness intact.

=item @methods = $resource->service_methods

Return the list of C<service_*_start> method names declared on the
consuming class, ordered by L</sort_methods>. Used by the harness to
discover and start supervised subprocesses for this resource. The
C<_start> suffix is required; companion methods
(C<service_XXX_applicable>, C<service_XXX_restartable>) do not carry
the suffix and are never enumerated here. See L</SERVICE METHODS>.

=item @ordered = $resource->sort_methods(@names)

Given the method names enumerated by L</service_methods>, return them
in the order the harness should start them. Default: alphabetical.
Override in a consumer to express explicit ordering (e.g. start a
database service before the worker that reads from it).

=item $resource->teardown

Called when the resource is being retired (harness shutdown for global
resources, run completion for per-run resources). Default: no-op.

=back

=head1 SERVICE METHODS

A resource may define one or more methods named
C<service_SOMETHING_start>. The harness introspects these via
L</service_methods> at initialization (for harness-global resources)
or at run start (for per-run resources) and invokes each one whose
optional companion C<service_SOMETHING_applicable> either does not
exist or returns true.

The service method is invoked with these named arguments:

    harness  => $harness,          # the Test2::Harness2 instance
    scope    => 'global' | 'run',  # global init vs per-run startup
    name     => $name,             # service name (the SOMETHING between 'service_' and '_start')
    log_path => $path,             # pre-created JSONL log file the harness has chosen
    run      => $run,              # only present when scope is 'run'

The harness guarantees that C<name> is unique within its scope (global
scope across all global services, per-run within each run; the
harness's own C<name> is reserved in the global scope). The
C<log_path> points at C<services/E<lt>nameE<gt>.jsonl> under the
workdir for global services, or
C<runs/E<lt>run_idE<gt>/services/E<lt>nameE<gt>.jsonl> for per-run
services. The file is pre-created, so a resource that spawns a
subprocess can redirect its child's stdout/stderr to C<log_path>
without checking.

The service method is responsible for starting the subprocess and
reporting its pid to the harness via:

    $harness->track_resource_service(
        pid      => $pid,
        resource => $self,
        method   => $method_name,
    );

B<The service method's return value is ignored.> Success is signalled
by returning normally; failure is signalled by throwing. If the method
dies, the harness catches the exception, marks the resource
C<permanent_broken>, and logs a C<resource_service_start_failed> event
through the host service's logger. The service startup loop continues
to the next service rather than aborting.

=head2 Companion methods

Two optional sibling methods tune the harness's treatment of each
service. Neither ends in C<_start>, so neither is enumerated by
C<service_methods>:

=over 4

=item $bool = $resource->service_XXX_applicable(%opts)

When present, called B<before> C<service_XXX_start> with the same named
arguments. Returning false skips the service entirely: no start
attempt, no tracking, no brokenness impact. When absent, the service
is always started.

=item $bool = $resource->service_XXX_restartable(%opts)

When present, returning true means the harness should auto-restart
the service if it exits before shutdown (unless the resource has
been marked C<permanent_broken>); returning false means a clean
exit is accepted and a failure flips the resource to
C<permanent_broken>. When this companion is absent the service is
non-restartable -- the role deliberately has no blanket
C<restartable> accessor, so there is only one place to look.

=back

=head2 Restart semantics

When a restartable service exits, the harness re-invokes its
C<service_*_start> method. Basic spiral protection caps consecutive restart
attempts at C<MAX_RESTART_ATTEMPTS> (currently 5); the counter resets
to 1 when a service survived at least C<RESTART_HEALTHY_SECS>
(currently 30) before exiting. Note that the reset is one-shot per
long-lived window: a service that survived 30s, died, and then
immediately crash-loops will burn up to C<MAX_RESTART_ATTEMPTS> rapid
retries before the resource is flipped to C<permanent_broken>. If the
re-invoked method dies, the resource stays C<broken> (no automatic
progression to C<permanent_broken>); operator intervention is
required.

If a resource is in a transient broken state while a test is still
running against it and that test later fails, the test should be
queued for re-run (retry logic is a future concern). If the resource
is permanently broken, the harness dispatches jobs that need it
according to its C<broken_resource_behavior> attribute (C<skip>,
C<fail>, or C<abort>); see L<Test2::Harness2>.

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
