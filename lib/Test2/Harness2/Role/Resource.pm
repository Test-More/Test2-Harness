package Test2::Harness2::Role::Resource;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

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

# Declare the supervised subprocesses this resource needs in the
# current environment. Each list entry is an arrayref:
#
#     [ $service_class, @construction_params ]
#
# $service_class must consume Test2::Harness2::Role::ResourceService;
# @construction_params are passed through to $service_class->new as-is,
# with the host layering name / log_path / ipcm_info on top before
# construction. A resource that has nothing to supervise in the current
# environment returns an empty list -- there is no separate
# "applicable" hook; the resource's own logic decides membership by
# including or omitting each service from the returned list.
sub services { () }

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

Resources may also declare one or more supervised subprocesses via the
L</services> method. The harness instantiates and supervises each one;
the resource itself never forks. See L</SERVICES> below.

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

    sub services {
        my $self = shift;
        return (
            [ 'My::Resource::Daemon', name => 'mydaemon', config => $self->config ],
        );
    }

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

=item @entries = $resource->services

Return the list of supervised subprocesses this resource requires.
Each entry is an arrayref:

    [ $service_class, @construction_params ]

C<$service_class> must consume L<Test2::Harness2::Role::ResourceService>.
C<@construction_params> are passed verbatim to
C<< $service_class->new >>; the host adds C<name>, C<log_path>, and
C<ipcm_info> on top before construction.

Default: empty list. A resource that only needs supervision in certain
environments returns an empty list when no service is applicable; there
is no separate "applicable" hook.

=item $resource->teardown

Called when the resource is being retired (harness shutdown for global
resources, run completion for per-run resources). Default: no-op.

=back

=head1 SERVICES

A resource declares its supervised subprocesses via L</services>. Each
entry names a class that consumes L<Test2::Harness2::Role::ResourceService>
plus the constructor arguments for one instance of that class. The host
is responsible for instantiating the service, spawning it, tracking its
pid, and restarting or retiring it when it exits. The resource itself
never forks.

The first argument of each construction-params list B<must> be C<name>
(followed by the service's desired unique name within its scope). The
host reads the name to derive the service's log file path and to
enforce per-scope name uniqueness.

Every service instance is constructed as:

    $service_class->new(
        @construction_params,
        name      => $name,         # mandatory; first pair in @construction_params
        log_path  => $log_path,     # host-derived from name + scope
        ipcm_info => $ipcm_info,    # host's IPC::Manager info
    );

Any additional arguments the resource wants to pass go before C<name>
in the params list.

=head2 Restartability

L<Test2::Harness2::Role::ResourceService/restartable> controls the
host's behaviour when the service exits before shutdown. A
non-restartable service that exits flips the owning resource to
C<permanent_broken>; a restartable service is re-spawned, subject to
spiral protection (C<$host-E<gt>max_restart_attempts>,
C<$host-E<gt>restart_healthy_secs>).

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
