package Test2::Harness2::Run::State;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Object::HashBase qw{
    <run_id
    <created_at
    pending
    running
    done
    results
    aborted_reason
    start_time
    finish_time
    completed
    exit_summary
    running_harness_uuid
    collector_uuid
    bus_address
    running_session_uuid
    +resources_started
    +resources_torn_down
};

sub init {
    my $self = shift;

    croak "'run_id' is a required attribute"
        unless defined $self->{+RUN_ID};

    $self->{+PENDING} //= [];
    $self->{+RUNNING} //= [];
    $self->{+DONE}    //= [];
    $self->{+RESULTS} //= {};
}

sub TO_JSON { return {%{$_[0]}} }

sub rehydrate {
    my $class = shift;
    my ($hash) = @_;
    croak "rehydrate requires a hashref" unless ref($hash) eq 'HASH';
    return $class->new(%$hash);
}

sub is_complete {
    my $self = shift;
    return !@{$self->{+PENDING}} && !@{$self->{+RUNNING}};
}

sub mark_started {
    my $self = shift;
    $self->{+START_TIME} //= time;
    return;
}

sub mark_finished {
    my $self = shift;
    $self->{+FINISH_TIME} //= time;
    $self->{+COMPLETED} = 1;
    return;
}

sub mark_running {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+PENDING}};
    croak "job_id '$job_id' is not pending" if @new == @{$self->{+PENDING}};
    $self->{+PENDING} = \@new;
    push @{$self->{+RUNNING}} => $job_id;
    return;
}

sub mark_done {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+RUNNING}};
    croak "job_id '$job_id' is not running" if @new == @{$self->{+RUNNING}};
    $self->{+RUNNING} = \@new;
    push @{$self->{+DONE}} => $job_id;
    return;
}

sub mark_skipped {
    my ($self, $job_id) = @_;
    my @new = grep { $_ ne $job_id } @{$self->{+PENDING}};
    croak "job_id '$job_id' is not pending" if @new == @{$self->{+PENDING}};
    $self->{+PENDING} = \@new;
    push @{$self->{+DONE}} => $job_id;
    return;
}

sub seed_pending {
    my ($self, @job_ids) = @_;
    push @{$self->{+PENDING}} => @job_ids;
    return;
}

sub record_job_result {
    my ($self, $job_id, %fields) = @_;
    croak "'job_id' is required" unless defined $job_id;
    my $r = $self->{+RESULTS}->{$job_id} //= {};
    for my $k (keys %fields) {
        $r->{$k} = $fields{$k};
    }
    return $r;
}

sub seed_job_result {
    my ($self, $job_id, %fields) = @_;
    croak "'job_id' is required" unless defined $job_id;
    my $r = $self->{+RESULTS}->{$job_id} //= {};
    for my $k (keys %fields) {
        $r->{$k} //= $fields{$k};
    }
    return $r;
}

# aborted_reason is "first writer wins" -- once set we do not overwrite,
# so the original cause survives any later abort attempts.
sub latch_aborted_reason {
    my ($self, $reason) = @_;
    $self->{+ABORTED_REASON} //= $reason;
    return;
}

# Object::HashBase auto-generates set_X writers for every slot without
# the `<` (read-only) modifier; the slots above (exit_summary,
# running_harness_uuid, collector_uuid, bus_address,
# running_session_uuid) are declared writable, so callers use the
# auto-generated set_* methods directly.

sub mark_resources_started   { $_[0]->{+RESOURCES_STARTED}   = 1 }
sub mark_resources_torn_down { $_[0]->{+RESOURCES_TORN_DOWN} = 1 }
sub resources_started_flag   { $_[0]->{+RESOURCES_STARTED} }
sub resources_torn_down_flag { $_[0]->{+RESOURCES_TORN_DOWN} }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Run::State - Mutable runtime state for a queued run.

=head1 DESCRIPTION

Companion to L<Test2::Harness2::Run> (the immutable spec). Where the spec
freezes "what was queued", the state tracks "what has happened since".
The run service owns the authoritative copy; the harness mirrors a copy
via C<run_state_update> IPC messages.

C<run_id> is the only field carried on both sides for self-identification
when one is read independently of the other; everything else lives only
on the State.

=head1 ATTRIBUTES

=over 4

=item run_id (required)

UUID of the parent L<Test2::Harness2::Run>. Canonical owner is the Spec;
the State carries it for self-identification when read in isolation.

=item pending / running / done

Arrayrefs of job_ids in each lifecycle bucket. Mutated through
C<mark_running>, C<mark_done>, C<mark_skipped>.

=item results

Hashref of job_id => per-job result fields (queued_at, started_at,
completed_at, pass, exit, codes, times, child_times, child_wall, file,
abs_file, rel_file, job_try, etc.). Mutated through C<record_job_result>
and C<seed_job_result>.

=item start_time / finish_time

Epoch timestamps when the run started executing and finished.

=item completed

Boolean: true once the run service has finalized this run.

=item exit_summary

Aggregate verdict / counters when the run terminates.

=item aborted_reason

Resource name (or other string) when the run was aborted before all
queued jobs ran.

=item running_harness_uuid

UUID of the harness that actually ran this run. Distinct from the
queue-time C<requested_harness_uuid> on the Spec, which is set only
when the user pinned a target harness up front.

=item collector_uuid

UUID identifying the collector instance that interposed on the run
service.

=item bus_address

Address of the IPC::Manager bus the run service joined.

=item running_session_uuid

UUID of the session this run executed under.

=back

=head1 METHODS

=over 4

=item $state = Test2::Harness2::Run::State->new(run_id => $id, ...)

=item $state = Test2::Harness2::Run::State->rehydrate(\%hash)

Construct from a hash that came back from C<TO_JSON>. Keeps the same
shape as the produced JSON; useful for replays.

=item $hash = $state->TO_JSON

Plain-hash dump of every slot.

=item $state->mark_started

Stamp C<start_time> with the current epoch (idempotent).

=item $state->mark_finished

Stamp C<finish_time> with the current epoch and set C<completed>.

=item $state->mark_running($job_id)

Move a job from pending to running. Croaks when the job is not pending.

=item $state->mark_done($job_id)

Move a job from running to done. Croaks when the job is not running.

=item $state->mark_skipped($job_id)

Move a job directly from pending to done. Croaks when the job is not
pending.

=item $state->seed_pending(@job_ids)

Initial pending-list seeding at run start.

=item $r = $state->record_job_result($job_id, %fields)

Set / overwrite per-job result fields. Returns the per-job hash.

=item $r = $state->seed_job_result($job_id, %fields)

Like record_job_result but only sets fields that are not already
defined. Used at queue time to seed metadata that the run service
should not blow away.

=item $state->latch_aborted_reason($reason)

Latch an abort reason (idempotent: first writer wins).

=item $state->set_exit_summary($summary)

(Auto-generated.) Stamp the final exit-summary blob (typically pass/fail
aggregate + counts) when the run finishes.

=item $state->set_running_harness_uuid($uuid)

=item $state->set_collector_uuid($uuid)

=item $state->set_bus_address($addr)

=item $state->set_running_session_uuid($uuid)

(Auto-generated by Object::HashBase.) Identity setters for the harness,
collector, bus, and session that actually executed the run. Distinct
from any C<requested_X> field on the Spec which records what the user
pinned at queue time.

=item $bool = $state->is_complete

True when both pending and running are empty.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
