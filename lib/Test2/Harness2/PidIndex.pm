package Test2::Harness2::PidIndex;
use strict;
use warnings;

our $VERSION = '2.000013';

use Time::HiRes qw/time/;
use Test2::Harness2::Util qw/tinysleep/;

use Object::HashBase qw{
    +run_pids
    +harness
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

# Sentinel run_id key used by the pid index for processes that aren't
# bound to a particular run -- e.g. global resource services. Picked
# so it can never collide with a real run_id (which are uuids).
use constant RUN_PIDS_GLOBAL_KEY => '__global__';

sub init {
    my $self = shift;
    $self->{+RUN_PIDS} //= {};
}

# Drop every tracked entry. Used by the harness's service_post_hard_stop
# wholesale reset; not normally called otherwise.
sub clear {
    my $self = shift;
    $self->{+RUN_PIDS} = {};
    return;
}

sub register {
    my ($self, $run_key, $pid, %meta) = @_;
    return unless defined $run_key && length $run_key;
    return unless defined $pid     && $pid > 0;
    $meta{started_at} //= time;
    $self->{+RUN_PIDS}->{$run_key}->{$pid} = \%meta;
    return $pid;
}

# Drop the (run_key, pid) entry. Returns the meta hash if it existed,
# or undef. Removes the per-run sub-hash entirely once it goes empty
# so iteration over active runs stays cheap.
sub forget {
    my ($self, $run_key, $pid) = @_;
    return unless defined $run_key && length $run_key;
    my $bucket = $self->{+RUN_PIDS}->{$run_key} or return;
    my $meta   = delete $bucket->{$pid};
    delete $self->{+RUN_PIDS}->{$run_key} unless keys %$bucket;
    return $meta;
}

# Reverse-lookup: given a pid, return ($run_key, \%meta). The map is
# small (active runs * active pids), so a linear scan is fine. Returns
# (undef, undef) when not found.
sub run_for_pid {
    my ($self, $pid) = @_;
    my $rp = $self->{+RUN_PIDS} // {};
    for my $run_key (keys %$rp) {
        my $meta = $rp->{$run_key}->{$pid};
        return ($run_key, $meta) if $meta;
    }
    return (undef, undef);
}

sub pids_for_run {
    my ($self, $run_key) = @_;
    return () unless defined $run_key && length $run_key;
    my $bucket = $self->{+RUN_PIDS}->{$run_key} or return ();
    return keys %$bucket;
}

# Send $signal to every pid bound to $run_key. Skips pids that no
# longer exist. Returns the count of signals successfully delivered.
sub kill_run {
    my ($self, $run_key, $signal) = @_;
    $signal //= 'TERM';
    my @pids = $self->pids_for_run($run_key) or return 0;
    my $sent = 0;
    for my $pid (@pids) {
        next unless kill 0 => $pid;
        $sent++ if kill $signal => $pid;
    }
    return $sent;
}

# Block (with periodic 20ms naps) until every tracked pid for $run_key
# has exited the pid index, or until $deadline (epoch seconds). Returns
# 1 if the run drained, 0 on timeout. Note: this method only *waits* --
# it does not reap. The reap path (harness run_on_pid) is what actually
# removes entries, which only fires when the IPC::Manager loop services
# SIGCHLD.
sub await_run_exit {
    my ($self, $run_key, $deadline) = @_;
    my $h = $self->harness;
    $deadline //= time + (($h && $h->kill_timeout) // 15);
    while ($self->pids_for_run($run_key)) {
        return 0 if time >= $deadline;
        tinysleep(0.02);
    }
    return 1;
}

# ResourceServiceHost notification hook: mirror every resource service
# registration into the pid map, keyed by run_id (per-run scope) or by
# RUN_PIDS_GLOBAL_KEY (global scope).
sub resource_service_tracked {
    my ($self, %p) = @_;
    my $scope = $p{scope} // 'global';
    my $run_key =
        ($scope eq 'run' && ref $p{run})
        ? $p{run}->run_id
        : RUN_PIDS_GLOBAL_KEY;
    my $h = $self->harness;
    my $svc = ($h && $h->resource_services && $h->resource_services->{$p{pid}}) || {};
    $self->register(
        $run_key, $p{pid},
        kind     => 'resource_service',
        res_name => $p{resource} ? $p{resource}->resource_name : undef,
        res_svc  => $p{name},
        scope    => $scope,
        ($svc->{started_at} ? (started_at => $svc->{started_at}) : ()),
    );
    return;
}

sub resource_service_forgotten {
    my ($self, %p) = @_;
    my $scope = $p{scope} // 'global';
    my $run_key =
        ($scope eq 'run' && ref $p{run})
        ? $p{run}->run_id
        : RUN_PIDS_GLOBAL_KEY;
    $self->forget($run_key, $p{pid});
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PidIndex - Per-run pid bookkeeping for the harness.

=head1 DESCRIPTION

The pid index is the single source of truth for per-run signal / kill /
wait operations. It keys every harness-spawned subprocess (run service,
test collector, resource service) by the C<run_id> it serves, with a
sentinel key (C<RUN_PIDS_GLOBAL_KEY>) for processes that aren't bound
to a particular run (currently: global resource services).

The harness constructs one PidIndex during its own C<init> and holds a
strong reference to it. The index holds a weakened backref to the
harness via L<Test2::Harness2::Role::Subsystem> so it can read the
harness's C<kill_timeout> for default C<await_run_exit> deadlines and
peek at C<resource_services> when mirroring a tracked entry's
C<started_at>.

Entry shape:

    $pi->{run_pids}->{$run_id}->{$pid} = {
        kind         => 'collector' | 'run_service' | 'resource_service',
        started_at   => $epoch,
        # per-kind metadata:
        job_id       => $job_id,        # collector
        job_try      => $job_try,       # collector
        res_name     => $resource_name, # resource_service
        res_svc      => $service_name,  # resource_service
    };

=head1 METHODS

=over 4

=item $pid = $pi->register($run_key, $pid, %meta)

Record C<$pid> under C<$run_key>. Auto-stamps C<started_at> if absent.
Returns the pid on success, or nothing if C<$run_key> / C<$pid> are
missing.

=item $meta = $pi->forget($run_key, $pid)

Drop the C<(run_key, pid)> entry. Returns the meta hash that was
removed, or C<undef> if it wasn't there. Empties run buckets are
removed entirely.

=item ($run_key, $meta) = $pi->run_for_pid($pid)

Reverse-lookup. Returns C<(undef, undef)> when the pid is not tracked.

=item @pids = $pi->pids_for_run($run_key)

Returns every pid currently tracked under C<$run_key>.

=item $count = $pi->kill_run($run_key, $signal)

Deliver C<$signal> (default C<TERM>) to every live pid bound to
C<$run_key>. Returns the count of signals successfully delivered.

=item $ok = $pi->await_run_exit($run_key, $deadline)

Block (with periodic 20ms naps) until every tracked pid for C<$run_key>
has exited, or until C<$deadline> (epoch seconds). When C<$deadline> is
omitted, defaults to C<time + harness->kill_timeout> (or 15s when no
harness is bound). Returns 1 on drain, 0 on timeout.

=item $pi->resource_service_tracked(%hooks)

L<Test2::Harness2::Role::ResourceServiceHost> notification hook. Mirrors
the registration into the pid map.

=item $pi->resource_service_forgotten(%hooks)

Companion to C<resource_service_tracked>; drops the mirrored entry.

=item $pi->clear

Reset every tracked entry. Used by the harness's wholesale shutdown
reset; not normally called otherwise.

=item $h = $pi->harness

Returns the harness reference, or C<undef> when no harness is bound or
the harness has gone away. Inherited from
L<Test2::Harness2::Role::Subsystem>.

=back

=head1 CONSTANTS

=over 4

=item RUN_PIDS_GLOBAL_KEY

Sentinel C<run_id> key for processes that aren't bound to a particular
run (e.g. global resource services). Chosen to never collide with a
real run_id (which are uuids).

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::Role::ResourceServiceHost>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
