package App::Yath2::Streamer::Base;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Event;

use Object::HashBase qw{
    <global
    <run
    <runs
    +known_states
    +known_artifacts
    +pending_actions
    +event_queue
    +event_readers
    +seen_run_start
    +seen_run_end
    +exit_requested
};

# Shared init: normalise run/runs into a de-duped list, seed the
# per-instance containers every Base method reads, then hand off to
# the subclass via _bootstrap for mode-specific setup (subscribe for
# live, archive open + state collection for static). Subclasses
# must not override init -- they override _bootstrap instead.
sub init {
    my $self = shift;

    my @runs;
    push @runs => $self->{+RUN}     if defined $self->{+RUN};
    push @runs => @{$self->{+RUNS}} if ref($self->{+RUNS}) eq 'ARRAY';
    my %seen;
    @runs = grep { !$seen{$_}++ } @runs;
    $self->{+RUNS} = \@runs;

    croak "At least one of 'global', 'run', or 'runs' must be provided"
        unless $self->{+GLOBAL} || @runs;

    $self->{+KNOWN_STATES}    = {};
    $self->{+KNOWN_ARTIFACTS} = {};
    $self->{+PENDING_ACTIONS} = {};
    $self->{+EVENT_QUEUE}     = [];
    $self->{+EVENT_READERS}   = {};
    $self->{+SEEN_RUN_START}  = {};
    $self->{+SEEN_RUN_END}    = {};
    $self->{+EXIT_REQUESTED}  = 0;

    $self->_bootstrap;

    return;
}

# Hook for subclasses. Default no-op so a streamer that does nothing
# on construction is still valid. Live uses it to subscribe; Static
# uses it to open the archive and prime the event / state readers.
sub _bootstrap { }

# Subclass contract: pull any new input, push resulting events onto
# EVENT_QUEUE. Default croaks so a broken subclass is caught
# immediately.
sub _tick { croak ref($_[0]) . " must override _tick()" }

# ----------------------------------------------------------------------
# Public API

sub stream {
    my $self = shift;
    my %params = @_;

    my $callback = $params{callback}
        or croak "'callback' coderef is required";
    croak "'callback' must be a coderef" unless ref($callback) eq 'CODE';

    my $exit_if = $params{exit_if};
    croak "'exit_if' must be a coderef"
        if defined $exit_if && ref($exit_if) ne 'CODE';

    while (1) {
        my $event = $self->next;
        if (defined $event) {
            $callback->($event);
            next;
        }

        last if $self->{+EXIT_REQUESTED};
        last if $exit_if && $exit_if->();

        # No event now, no exit: wait a short beat.
        sleep 0.05;
    }

    # Final drain after exit requested: loop pulls already-queued
    # events + whatever _tick produces one more time. next() returns
    # undef when nothing left.
    $self->{+EXIT_REQUESTED} = 1;
    $self->_tick;
    while (defined(my $event = $self->next)) {
        $callback->($event);
    }

    return;
}

sub next {
    my $self = shift;

    $self->_tick unless @{$self->{+EVENT_QUEUE}};

    return shift @{$self->{+EVENT_QUEUE}};
}

sub request_exit { $_[0]->{+EXIT_REQUESTED} = 1 }

# ----------------------------------------------------------------------
# State synthesis. Given a fresh Run snapshot, diff against the last
# known state for the same run and emit any lifecycle events for the
# transitions. Shared between live (called per IPC state message) and
# static (called once per run at bootstrap, diffing against an empty
# prior).
sub _apply_run_state {
    my ($self, $run_id, $state) = @_;

    my $prior = $self->{+KNOWN_STATES}->{$run_id};
    $self->{+KNOWN_STATES}->{$run_id} = $state;

    # run_start is the first event for a run.
    unless ($self->{+SEEN_RUN_START}->{$run_id}) {
        $self->{+SEEN_RUN_START}->{$run_id} = 1;
        $self->_enqueue_event(
            run_id     => $run_id,
            stamp      => $state->{created_at} // time,
            facet_data => {
                harness_run => _harness_run_facet($state),
            },
        );
    }

    my $prior_results = ($prior && ref($prior->{results}) eq 'HASH') ? $prior->{results} : {};
    my $results       = ref($state->{results}) eq 'HASH' ? $state->{results} : {};

    # Walk jobs in a stable order: by queued_at stamp then job_id.
    my @jobs =
        sort {
            (($results->{$a}{queued_at} // 0) <=> ($results->{$b}{queued_at} // 0))
                || ($a cmp $b)
        }
        keys %$results;

    for my $jid (@jobs) {
        my $now = $results->{$jid};
        my $was = $prior_results->{$jid};

        # queued -> seen for the first time
        if (!$was && defined $now->{queued_at}) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{queued_at},
                facet_data => {
                    harness_job_queued => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{queued_at},
                    },
                },
            );
        }

        # started_at transitions: emit once when it first appears
        if (defined $now->{started_at} && !($was && defined $was->{started_at})) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{started_at},
                facet_data => {
                    harness_job_start => {
                        job_id   => $jid,
                        file     => $now->{abs_file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        stamp    => $now->{started_at},
                        details  => "Launched " . ($now->{rel_file} // $jid) . " as job $jid.",
                    },
                },
            );
        }

        # completed_at transitions: emit once when it first appears
        if (defined $now->{completed_at} && !($was && defined $was->{completed_at})) {
            $self->_enqueue_event(
                run_id     => $run_id,
                job_id     => $jid,
                job_try    => $now->{job_try} // 0,
                stamp      => $now->{completed_at},
                facet_data => {
                    harness_job_end => {
                        job_id   => $jid,
                        file     => $now->{abs_file} // $now->{file},
                        abs_file => $now->{abs_file},
                        rel_file => $now->{rel_file},
                        fail     => $now->{pass} ? 0 : 1,
                        stamp    => $now->{completed_at},
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                        (defined $now->{times} ? (times => $now->{times}) : ()),
                    },
                    harness_job_exit => {
                        job_id => $jid,
                        (defined $now->{exit}  ? (exit  => $now->{exit})  : ()),
                        (defined $now->{codes} ? (codes => $now->{codes}) : ()),
                        stamp => $now->{completed_at},
                    },
                },
            );
        }
    }

    # run_end: emitted when the run reports complete state (either the
    # harness has wrapped it up or the snapshot says so explicitly).
    my $complete =
           (defined $state->{state} && $state->{state} eq 'complete')
        || (ref($state->{pending}) eq 'ARRAY' && ref($state->{running}) eq 'ARRAY'
            && !@{$state->{pending}} && !@{$state->{running}} && %$results);

    if ($complete && !$self->{+SEEN_RUN_END}->{$run_id}) {
        $self->{+SEEN_RUN_END}->{$run_id} = 1;

        my $stamp = _max_completed_at($results) // time;
        $self->_enqueue_event(
            run_id     => $run_id,
            stamp      => $stamp,
            facet_data => {
                harness_run_end => _harness_run_end_facet($run_id, $state),
                harness_run     => _harness_run_facet($state),
            },
        );
    }

    return;
}

# Drain any event readers attached by the subclass. Shared so both
# live (general-event readers attached on artifact IPC messages) and
# static (readers attached at bootstrap) go through the same loop.
sub _drain_event_readers {
    my $self = shift;

    for my $rel (keys %{$self->{+EVENT_READERS}}) {
        # Per-job test logs live at runs/<run_id>/tests/<job_id>/<try>.<ext>
        # in the Phase 4.5 layout (per-try basename in a per-job
        # directory); the on-disk events don't carry job_id inside
        # each record, so inject it here from the artifact path.
        # Without this the renderer attributes test asserts to
        # "RUNNER" instead of the owning job.
        #
        # The pre-4.5 per-job-only path (runs/<run>/tests/<job>.<ext>)
        # is still recognised at read-time for archives produced before
        # this change; new writers always go through the 4.5 layout.
        my ($injected_run_id, $injected_job_id);
        if ($rel =~ m{^runs/([^/]+)/tests/([^/]+)/[^/]+\.[^/]+$}) {
            ($injected_run_id, $injected_job_id) = ($1, $2);
        }
        elsif ($rel =~ m{^runs/([^/]+)/tests/([^/]+)\.[^/]+$}) {
            ($injected_run_id, $injected_job_id) = ($1, $2);
        }

        for my $pair (@{$self->{+EVENT_READERS}->{$rel}}) {
            my ($class, $reader) = @$pair;
            next unless $class->ready($reader);
            my @events = $class->fetch_events($reader);
            for my $hash (@events) {
                next unless ref($hash) eq 'HASH';
                if (defined $injected_job_id) {
                    $hash->{run_id}  //= $injected_run_id;
                    $hash->{job_id}  //= $injected_job_id;
                    my $fd = $hash->{facet_data} //= {};
                    my $h  = $fd->{harness}      //= {};
                    $h->{run_id} //= $injected_run_id;
                    $h->{job_id} //= $injected_job_id;
                }
                push @{$self->{+EVENT_QUEUE}} => $self->_bless_event($hash);
            }
        }
    }

    return;
}

# ----------------------------------------------------------------------
# Helpers (shared, but called only from state-diff code in this base).

sub _enqueue_event {
    my ($self, %fields) = @_;
    push @{$self->{+EVENT_QUEUE}} => $self->_bless_event(\%fields);
    return;
}

sub _bless_event {
    my ($self, $hash) = @_;

    return $hash if blessed($hash) && $hash->isa('Test2::Harness2::Event');

    my %copy = %$hash;
    $copy{event_id}   //= gen_uuid();
    $copy{stamp}      //= time;
    $copy{facet_data} //= {};

    return Test2::Harness2::Event->new(\%copy);
}

sub _harness_run_facet {
    my ($state) = @_;
    return {
        run_id => $state->{run_id},
        (defined $state->{created_at}      ? (created_at => $state->{created_at})        : ()),
        (ref($state->{pending}) eq 'ARRAY' ? (pending    => [@{$state->{pending}}])      : ()),
        (ref($state->{running}) eq 'ARRAY' ? (running    => [@{$state->{running}}])      : ()),
        (ref($state->{done})    eq 'ARRAY' ? (done       => [@{$state->{done}}])         : ()),
    };
}

sub _harness_run_end_facet {
    my ($run_id, $state) = @_;

    my $results  = ref($state->{results}) eq 'HASH' ? $state->{results} : {};
    my $all_pass = 1;
    my ($fail_count, $pass_count) = (0, 0);
    my @cpu_agg     = (0, 0, 0, 0);
    my $have_times  = 0;
    my $cum_job_wall = 0;
    my $have_wall    = 0;

    for my $jid (keys %$results) {
        next unless defined $results->{$jid}{completed_at};
        if ($results->{$jid}{pass}) { $pass_count++ }
        else                        { $fail_count++; $all_pass = 0 }
        if (my $t = $results->{$jid}{child_times}) {
            $cpu_agg[$_] += $t->[$_] for 0 .. 3;
            $have_times = 1;
        }
        if (defined(my $w = $results->{$jid}{child_wall})) {
            $cum_job_wall += $w;
            $have_wall = 1;
        }
    }

    my $stamp     = _max_completed_at($results) // time;
    my $wall_time = defined $state->{created_at} ? ($stamp - $state->{created_at}) : undef;

    my %timing;
    $timing{wall_time}            = $wall_time     if defined $wall_time;
    $timing{cumulative_job_time}  = $cum_job_wall  if $have_wall;

    if ($have_times) {
        my $cpu_total = $cpu_agg[0] + $cpu_agg[1] + $cpu_agg[2] + $cpu_agg[3];
        $timing{cpu_times} = \@cpu_agg;
        $timing{cpu_total} = $cpu_total;
        # CPU Usage relative to Run Wall: aggregate CPU-cores worth of
        # work performed by all test jobs during the run. With high
        # parallelism this can exceed 100% (one core = 100%).
        $timing{cpu_usage}
            = ($wall_time && $wall_time > 0) ? int($cpu_total / $wall_time * 100) : 0;
    }

    return {
        run_id     => $run_id,
        pass       => $all_pass ? 1 : 0,
        pass_count => $pass_count,
        fail_count => $fail_count,
        stamp      => $stamp,
        %timing,
    };
}

sub _max_completed_at {
    my ($results) = @_;
    my $max;
    for my $jid (keys %$results) {
        my $t = $results->{$jid}{completed_at};
        next unless defined $t;
        $max = $t if !defined $max || $t > $max;
    }
    return $max;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Streamer::Base - Shared backbone for live and static streamers.

=head1 DESCRIPTION

Abstract base class for L<App::Yath2::Streamer::Live> and
L<App::Yath2::Streamer::Static>. Carries the state-diff + event-queue
+ event-reader machinery; leaves per-mode input and bootstrap to
subclasses via C<_bootstrap> and C<_tick>.

Do not instantiate directly.

=head1 SUBCLASS CONTRACT

=over 4

=item $self->_bootstrap

Called once at the tail of C<init>. Mode-specific setup
(subscribe, archive open, etc.).

=item $self->_tick

Called each time the event queue is drained dry. Mode-specific input
source: Live polls its IPC handle and drains its readers, Static just
drains its readers.

=back

=head1 SHARED STATE

HashBase slots the subclasses (and the methods here) use:

=over 4

=item global / run / runs

Subscription scope. Validated at construction.

=item known_states

Per-run snapshot cache for diffing.

=item known_artifacts

Per-scope artifact table.

=item event_queue

FIFO of Test2::Harness2::Event objects ready to hand out via L</next>.

=item event_readers

Per-artifact-path arrayref of C<< [$class, $reader] >> pairs the
subclass opened; L</_drain_event_readers> polls each per tick.

=item seen_run_start / seen_run_end

Per-run flags so lifecycle events for a given run fire exactly once.

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

See L<http://dev.perl.org/licenses/>

=cut
