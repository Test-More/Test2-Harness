package Test2::Harness2::PreloadRouter;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Object::HashBase qw{
    +pending_spawn_requests
    +pending_preload_spawns
    +resources_awaiting_preload
    +known_preload_names
    +preload_spawn_timeout_secs
    +preload_service_spawn_timeout_secs
    +harness
    +run_states
    +pid_index
    +scheduler
    +job_tracker
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

sub init {
    my $self = shift;

    croak "'harness' is required"     unless $self->{+HARNESS};
    croak "'run_states' is required"  unless $self->{+RUN_STATES};
    croak "'pid_index' is required"   unless $self->{+PID_INDEX};
    croak "'scheduler' is required"   unless $self->{+SCHEDULER};
    croak "'job_tracker' is required" unless $self->{+JOB_TRACKER};

    $self->{+PENDING_SPAWN_REQUESTS}              //= {};
    $self->{+PENDING_PRELOAD_SPAWNS}              //= {};
    $self->{+RESOURCES_AWAITING_PRELOAD}          //= {};
    $self->{+KNOWN_PRELOAD_NAMES}                 //= {};
    $self->{+PRELOAD_SPAWN_TIMEOUT_SECS}          //= 30;
    $self->{+PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS}  //= 30;

    return;
}

#-------------------------------------------------------------------
# Per-tick orchestration: the harness's run_on_interval calls tick
# once per loop iteration. The two watchdogs that previously ran
# inline on the harness fold in here, in the same order, so timing
# semantics are preserved exactly.
#-------------------------------------------------------------------
sub tick {
    my $self = shift;
    $self->age_pending_spawn_requests;
    $self->check_pending_preload_spawn_timeouts;
    return;
}

#-------------------------------------------------------------------
# Preload resolution.
#
# resolve_for_job($run, $job) walks the job's preload preference list
# (parsed from `HARNESS2: preload ...` at scan time, default
# ['<default>']) and returns one of:
#
#   (undef, 'no_preload')          -> use the direct-fork path.
#   ($resource, 'preload')         -> spawn the test via $resource's
#                                     preload service.
#   (undef, 'defer')               -> at least one candidate is not yet
#                                     ready (transient broken / not yet
#                                     usable); retry on the next
#                                     scheduler tick.
#   (undef, 'broken', $first_name) -> list exhausted with no acceptable
#                                     resolution and nothing
#                                     defer-eligible; caller routes
#                                     through broken_resource_behavior.
#
# A `<no>` token is the explicit opt-out and always resolves to
# no_preload, even when earlier candidates were broken or missing.
#
# A `<default>` token resolves to the per-run default (if one exists
# for the current run) and falls through to the global default; if
# neither default is configured, `<default>` resolves to no_preload
# (its implicit <no> fallback).
#-------------------------------------------------------------------
sub resolve_for_job {
    my ($self, $run, $job) = @_;

    my $prefs = $job->test_file->preload_preferences;
    return (undef, 'no_preload') unless $prefs && @$prefs;

    my $idx = $self->_index_for_run($run);

    my $deferred = 0;
    my $first_name;

    for my $entry (@$prefs) {
        $first_name //= $entry;

        return (undef, 'no_preload') if $entry eq '<no>';

        if ($entry eq '<default>') {
            my $cand = $idx->{run_default} // $idx->{global_default};
            return (undef, 'no_preload') unless $cand;    # implicit <no>
            my $verdict = _classify_state($cand);
            return ($cand, 'preload') if $verdict eq 'usable';
            $deferred++                if $verdict eq 'defer';
            return (undef, 'no_preload') if $verdict eq 'permanent';
            next;
        }

        # Bare name: per-run preferred over global.
        my $cand = $idx->{by_run}{$entry} // $idx->{by_global}{$entry};
        next unless $cand;    # missing: skip; broken verdict from exhaustion

        my $verdict = _classify_state($cand);
        return ($cand, 'preload') if $verdict eq 'usable';
        $deferred++              if $verdict eq 'defer';
        # permanent: keep scanning -- a later <no>/named candidate may accept.
    }

    return (undef, 'defer') if $deferred;
    return (undef, 'broken', $first_name // '');
}

# Build (scope, name) index of preload resources visible to this run.
# Per-run preloads are only included when their run_id matches.
sub _index_for_run {
    my ($self, $run) = @_;

    my $h = $self->harness;
    my $global = $h ? ($h->{Test2::Harness2::RESOURCES()} // []) : [];

    my @all = (
        @$global,
        (ref($run) ? @{$run->resources // []} : ()),
    );
    my @preloads = grep {
        blessed($_) && $_->isa('Test2::Harness2::Resource::Preload')
    } @all;

    my $run_id = ref($run) ? $run->run_id : undef;

    my (%by_global, %by_run, @globals_role, @run_role);
    my ($global_named_default, $run_named_default);

    for my $r (@preloads) {
        my $name = $r->name;
        if ($r->scope eq 'run') {
            my $rid = ref($r->run) ? $r->run->run_id : undef;
            next unless defined $run_id && defined $rid && $run_id eq $rid;
            $by_run{$name}     = $r;
            push @run_role => $r if $r->is_role_consumer;
            $run_named_default = $r if $name eq 'default';
        }
        else {
            $by_global{$name}     = $r;
            push @globals_role => $r if $r->is_role_consumer;
            $global_named_default = $r if $name eq 'default';
        }
    }

    # Default precedence: an explicit `default`-named preload (the
    # bare-module bucket from `-P Foo`) wins over the "exactly one
    # role consumer" rule.
    return {
        by_global      => \%by_global,
        by_run         => \%by_run,
        global_default => $global_named_default // (@globals_role == 1 ? $globals_role[0] : undef),
        run_default    => $run_named_default    // (@run_role == 1     ? $run_role[0]     : undef),
    };
}

# Package-function: not a method. Classification depends only on the
# resource's own state, so no $self needed.
sub _classify_state {
    my ($r) = @_;
    return 'permanent' if $r->is_permanent_broken;
    return 'usable'    if $r->is_usable;
    return 'defer';                  # transient broken OR not yet ready
}

#-------------------------------------------------------------------
# Peer-name derivation. Mirrors PreloadService's name derivation so
# the resolver-side and spawn-side wiring agree on the bus name.
#-------------------------------------------------------------------

# Derive the bus name the harness uses to talk to a PreloadService
# instance. preload-<n> for global, preload-<run_id>-<n> for run scope.
sub peer_name_for_preload {
    my (undef, $res) = @_;
    my $n = $res->name;
    return "preload-$n" if $res->scope eq 'global';
    my $rid = $res->run->run_id;
    return "preload-$rid-$n";
}

# Deterministic peer name for a resource service spawned via preload.
# resource-<n> for global scope, resource-<run_id>-<n> for run scope.
sub peer_name_for_resource {
    my (undef, $entry) = @_;
    my $n     = $entry->{name};
    my $scope = $entry->{scope} // 'global';
    return "resource-$n" if $scope eq 'global';
    my $rid = $entry->{run};
    $rid = $rid->run_id if ref($rid) && $rid->can('run_id');
    return "resource-$n" unless defined $rid && length $rid;
    return "resource-$rid-$n";
}

#-------------------------------------------------------------------
# Eligible preload lookup. Walks the harness's RESOURCE_SERVICES map
# and returns the entry for a live, global-scope, not-permanent_broken
# PreloadService whose resource.name matches $pname. Initial design
# covers global-scope preloads only; run-scoped reuse is a follow-up.
#-------------------------------------------------------------------
sub find_eligible {
    my ($self, $pname) = @_;
    return undef unless defined $pname && length $pname;

    my $h = $self->harness or return undef;
    my $svcs = $h->{Test2::Harness2::RESOURCE_SERVICES()} // {};

    for my $info (values %$svcs) {
        next unless ($info->{service_class} // '') eq 'Test2::Harness2::PreloadService';
        next unless ($info->{scope}         // '') eq 'global';
        my $res = $info->{resource};
        next unless ref($res) && $res->can('name');
        next unless $res->name eq $pname;
        next if $res->can('is_permanent_broken') && $res->is_permanent_broken;
        next unless defined $info->{pid} && kill 0 => $info->{pid};
        return $info;
    }
    return undef;
}

#-------------------------------------------------------------------
# Preload-mediated test job spawn. The preload service owns the fork
# (pre_fork hook, fork, post_fork hook, second fork, _exit(0) in the
# middle layer, grandchild runs the test).
#
# Records a placeholder running-job entry with pid=>undef; the
# grandchild's auditor lands a test_job_started which the harness's
# job-tracker uses to fill in the real pid and register the collector
# pid in the pid index. PENDING_SPAWN_REQUESTS tracks the in-flight
# request for timeout protection.
#-------------------------------------------------------------------
sub spawn_via_preload {
    my ($self, $run, $job, $preload_resource, %opts) = @_;

    my $h = $self->harness or croak "harness gone away";

    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;

    my $test_file_abs = $job->test_file_abs;
    croak "'test_file' must be absolute"
        unless File::Spec->file_name_is_absolute($test_file_abs);

    my $now = time;
    $self->_register_pending($run, $job, $preload_resource, $now, \%opts);

    my $payload = $self->_build_spawn_test_payload($run, $job, $test_file_abs, \%opts);
    my $peer    = $self->peer_name_for_preload($preload_resource);

    my $send_ok = eval { $h->client->send_message($peer, $payload); 1 };
    unless ($send_ok) {
        my $send_err = $@;
        # Roll back so the caller's launch_failed path (which releases
        # assigned resources) can take over cleanly.
        $self->{+JOB_TRACKER}->take_running_job($job_id);
        delete $self->{+PENDING_SPAWN_REQUESTS}->{"$run_id\0$job_id"};
        croak "Failed to dispatch spawn_test to '$peer': $send_err";
    }

    return;
}

sub _register_pending {
    my ($self, $run, $job, $preload_resource, $now, $opts) = @_;
    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    $self->{+JOB_TRACKER}->set_running_job($job_id, {
        run                  => $run,
        job                  => $job,
        pid                  => undef,
        awaiting_preload_pid => 1,
        preload_name         => $preload_resource->name,
        preload_scope        => $preload_resource->scope,
        started_at           => $now,
        assign_id            => $opts->{assign_id},
        assigned_resources   => $opts->{assigned_resources} // [],
        log_file             => undef,
    });

    $self->{+PENDING_SPAWN_REQUESTS}->{"$run_id\0$job_id"} = {
        run_id        => $run_id,
        job_id        => $job_id,
        sent_at       => $now,
        preload_name  => $preload_resource->name,
        preload_scope => $preload_resource->scope,
    };
}

sub _build_spawn_test_payload {
    my ($self, $run, $job, $test_file_abs, $opts) = @_;
    my $h = $self->harness or croak "harness gone away";

    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;
    my $job_try = $job->job_try // 1;
    my $env     = $opts->{env}    // {};
    my $launch  = $opts->{launch};
    my $ch_dir  = $opts->{ch_dir};

    require Test2::Harness2::TestFile;
    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    my $queued_at;
    if (my $rs = $self->{+RUN_STATES}->state($run_id)) {
        my $r = $rs->results->{$job_id};
        $queued_at = $r->{queued_at} if $r && defined $r->{queued_at};
    }

    return {
        kind          => 'spawn_test',
        run_id        => $run_id,
        job_id        => $job_id,
        job_try       => $job_try,
        test_file_abs => $test_file_abs,
        env           => {T2_FORMATTER => 'Stream2', %$env},
        auditor       => $h->{Test2::Harness2::TEST_AUDITOR()},
        ipc_parent    => $h->{Test2::Harness2::NAME()},
        ipc_run       => $h->{Test2::Harness2::NAME()},
        ipc_harness   => $h->{Test2::Harness2::NAME()},
        kill_timeout  => $h->{Test2::Harness2::KILL_TIMEOUT()},
        logdir        => $h->{Test2::Harness2::LOGDIR()},
        spec          => {
            %{$test_file_spec->TO_JSON},
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job_try,
            (defined $queued_at ? (queued_at => $queued_at) : ()),
        },
        (defined $launch ? (launch => $launch) : ()),
        (defined $ch_dir && length $ch_dir ? (ch_dir => $ch_dir) : ()),
    };
}

#-------------------------------------------------------------------
# Resource-service spawn via an already-running preload. Asks the
# preload to fork another service for us. Distinct from
# spawn_via_preload (which spawns test-job collectors): this one
# spawns a *resource service*. The split keeps the two payload shapes
# ('spawn_test' vs 'spawn_service') from sharing state and
# pending-table semantics.
#
# Returns the allocated spawn_id on dispatch success, undef on send
# failure (caller falls back to standalone).
#-------------------------------------------------------------------
sub spawn_service_via_preload {
    my ($self, $preload_info, $entry) = @_;

    my $h = $self->harness or return undef;

    my $spawn_id  = ++$h->{_PRELOAD_SPAWN_COUNTER};
    my $peer_name = $self->peer_name_for_resource($entry);

    # The resource_services tracking entry keys the service under the
    # name extracted from its ctor args. That is NOT the IPC bus name --
    # PreloadService advertises itself as 'preload-<name>' (or
    # 'preload-<run_id>-<name>' for run scope). Send to the bus name,
    # not the tracking name, or the message is rejected as "not a valid
    # message recipient".
    my $preload_bus_name = $self->peer_name_for_preload($preload_info->{resource});

    $self->{+PENDING_PRELOAD_SPAWNS}->{$spawn_id} = {
        entry        => $entry,
        peer_name    => $peer_name,
        preload_pid  => $preload_info->{pid},
        preload_name => $preload_bus_name,
        sent_at      => time,
    };

    my $client = $h->client;
    my $ok = eval {
        $client->send_message($preload_bus_name, {
            kind      => 'spawn_service',
            class     => $entry->{service_class},
            peer_name => $peer_name,
            ctor_args => do {
                my $ca = { %{ $entry->{service_args} // {} } };
                my $wp = $ca->{watch_pids} // [];
                $wp = [$wp] unless ref($wp) eq 'ARRAY';
                $ca->{watch_pids} = [ @$wp, $h->pid ];
                $ca;
            },
            notify_to => $h->name,
            spawn_id  => $spawn_id,
        });
        1;
    };
    my $err = $@;

    unless ($ok) {
        delete $self->{+PENDING_PRELOAD_SPAWNS}->{$spawn_id};
        warn "Test2::Harness2: preload spawn dispatch to '$preload_bus_name' failed: $err\n";
        return undef;
    }

    return $spawn_id;
}

#-------------------------------------------------------------------
# General-message handlers for preload-related IPC.
#-------------------------------------------------------------------

# Finalize a preload-mediated resource spawn. The grandchild's
# notification carries pid + spawn_id; we look up the pending entry,
# clear it, and register the new pid in resource_services via
# track_resource_service. Emits resource_spawn_via_preload for
# operator visibility.
sub handle_service_started {
    my ($self, $content) = @_;
    my $h = $self->harness or return;

    return unless $content->{via_preload};

    my $sid = $content->{spawn_id};
    return unless defined $sid;

    my $pending = delete $self->{+PENDING_PRELOAD_SPAWNS}->{$sid}
        or return;    # unknown / stale spawn_id

    my $entry = $pending->{entry};
    my $pid   = $content->{pid};

    my $args_ref = ref($entry->{service_args}) eq 'HASH'
        ? [%{$entry->{service_args}}]
        : ($entry->{service_args} // []);

    # Track under the bus peer name ('resource-myappservice') so the
    # human-facing `yath ps` / `yath resources` output continues to show
    # the IPC peer name. Carry the raw entry name as `entry_name` so the
    # restart path can rebuild the bus name through peer_name_for_resource
    # without double-prefixing into 'resource-resource-myappservice' on
    # every restart cycle.
    $h->track_resource_service(
        pid           => $pid,
        resource      => $entry->{resource},
        service_class => $entry->{service_class},
        service_args  => $args_ref,
        name          => $pending->{peer_name},
        entry_name    => $entry->{name},
        log_path      => $entry->{log_path},
        scope         => $entry->{scope},
        (defined $entry->{run} ? (run => $entry->{run}) : ()),
        started_at    => time,
        attempts      => $entry->{attempts} // 1,
        via_preload   => 1,
    );

    $h->emit_service_event(
        kind          => 'resource_spawn_via_preload',
        resource      => (ref($entry->{resource}) && $entry->{resource}->can('resource_name')
                          ? $entry->{resource}->resource_name : '?'),
        service_class => $entry->{service_class},
        name          => $pending->{peer_name},
        scope         => $entry->{scope} // 'global',
        preload_name  => $pending->{preload_name},
        preload_pid   => $pending->{preload_pid},
        pid           => $pid,
        spawn_id      => $sid,
    );

    return;
}

# preload_ready / preload_broken IPC. Flips the matching Resource::Preload
# state, then drives the dependent-resource queue.
sub handle_preload_state {
    my ($self, $kind, $content) = @_;

    return unless ref($content) eq 'HASH';
    my $name  = $content->{preload_name};
    my $scope = $content->{scope} // 'global';
    return unless defined $name;

    $self->_apply_preload_state_to_resource($kind, $name, $scope, $content);

    # Drain any dependent resource services that were queued waiting
    # for this preload. preload_ready dispatches them through the
    # preload; permanent preload_broken flushes them to standalone so
    # they still come up (just unpreloaded). Transient preload_broken
    # leaves the queue intact so a subsequent preload_ready can still
    # drain it.
    if ($kind eq 'preload_ready') {
        $self->drain_awaiting($name);
    }
    elsif ($kind eq 'preload_broken' && $content->{permanent}) {
        $self->fallback_awaiting($name);
    }

    return;
}

# Find the Resource::Preload that matches this (name, scope, run_id)
# tuple and flip its state. mark_ready is itself permanent_broken-aware
# so cross-scope reuses of the same name can't promote a sibling via a
# foreign-scope preload_ready.
sub _apply_preload_state_to_resource {
    my ($self, $kind, $name, $scope, $content) = @_;

    my $h = $self->harness or return;
    my $run_id = $content->{run_id};

    # Look in both global resources and every queued run's per-run
    # resources -- a per-run preload's mark_ready signal otherwise
    # never lands on its Resource::Preload and the resolver defers
    # forever.
    my @candidates = @{$h->{Test2::Harness2::RESOURCES()} // []};
    if (my $sch = $self->{+SCHEDULER}) {
        for my $run (@{$sch->queue // []}) {
            push @candidates => @{$run->resources // []};
        }
    }

    for my $res (@candidates) {
        next unless blessed($res) && $res->isa('Test2::Harness2::Resource::Preload');
        next unless $res->name eq $name;
        next unless $res->scope eq $scope;
        if ($scope eq 'run') {
            next unless defined $run_id;
            my $r_run = $res->run;
            next unless ref($r_run);
            next unless $r_run->run_id eq $run_id;
        }

        if    ($kind eq 'preload_ready')  { $res->mark_ready }
        elsif ($kind eq 'preload_broken') { $res->mark_broken }
        last;
    }

    return;
}

#-------------------------------------------------------------------
# Resource-awaiting-preload queue drains.
#-------------------------------------------------------------------

# Drain the wait-for-preload queue for $pname through
# spawn_service_via_preload. Called from handle_preload_state when
# preload_ready arrives. If for some reason the preload is no longer
# eligible by the time we reach here (raced with permanent_broken,
# etc.) the entries fall back to standalone with a fallback event.
sub drain_awaiting {
    my ($self, $pname) = @_;
    return unless defined $pname && length $pname;

    my $queue = delete $self->{+RESOURCES_AWAITING_PRELOAD}->{$pname};
    return unless ref($queue) eq 'ARRAY' && @$queue;

    my $preload_info = $self->find_eligible($pname);
    for my $entry (@$queue) {
        if ($preload_info) {
            $self->spawn_service_via_preload($preload_info, $entry);
        }
        else {
            $self->_fallback_entry($entry, $pname, 'preload not eligible at drain time');
        }
    }
    return;
}

# Flush the wait-for-preload queue for $pname through
# _ipcm_service_standalone. Called when the preload reports
# permanent_broken: the dependents still come up, just unpreloaded.
sub fallback_awaiting {
    my ($self, $pname) = @_;
    return unless defined $pname && length $pname;

    my $queue = delete $self->{+RESOURCES_AWAITING_PRELOAD}->{$pname};
    return unless ref($queue) eq 'ARRAY' && @$queue;

    for my $entry (@$queue) {
        $self->_fallback_entry($entry, $pname, 'preload permanent_broken');
    }
    return;
}

# Helper: emit the fallback event for one queued entry and re-dispatch
# it through _ipcm_service_standalone. Shared between the drain and
# fallback paths so the event shape stays consistent.
sub _fallback_entry {
    my ($self, $entry, $pname, $reason) = @_;
    my $h = $self->harness or return;

    my $res = $entry->{resource};
    $h->emit_service_event(
        kind          => 'resource_spawn_preload_fallback',
        resource      => (ref($res) && $res->can('resource_name')
                          ? $res->resource_name : '?'),
        service_class => $entry->{service_class},
        name          => $entry->{name},
        scope         => $entry->{scope} // 'global',
        preload_name  => $pname,
        reason        => $reason,
    );

    my $args = ref($entry->{service_args}) eq 'HASH'
        ? [%{$entry->{service_args}}]
        : ($entry->{service_args} // []);

    $h->_ipcm_service_standalone(
        resource => $res,
        class    => $entry->{service_class},
        args     => $args,
        name     => $entry->{name},
        log_path => $entry->{log_path},
        scope    => $entry->{scope} // 'global',
        (defined $entry->{run} ? (run => $entry->{run}) : ()),
    );

    return;
}

#-------------------------------------------------------------------
# Per-tick watchdogs (called from tick()).
#-------------------------------------------------------------------

# Walk PENDING_SPAWN_REQUESTS; for any entry past
# preload_spawn_timeout_secs without a matching test_job_started,
# release the placeholder, flag the preload transient broken, and
# bounce the job back to pending so the next scheduler tick can
# re-attempt (either through the same preload once it recovers, or
# through a fallback path in the preference list).
sub age_pending_spawn_requests {
    my $self = shift;

    my $pending = $self->{+PENDING_SPAWN_REQUESTS};
    return unless $pending && keys %$pending;

    my $h = $self->harness or return;

    my $timeout      = $self->{+PRELOAD_SPAWN_TIMEOUT_SECS} || 30;
    my $now          = time;
    my $jt           = $self->{+JOB_TRACKER};
    my $running_jobs = $jt->running_jobs;

    for my $key (keys %$pending) {
        my $entry = $pending->{$key};
        next if ($now - $entry->{sent_at}) < $timeout;

        my $run_id = $entry->{run_id};
        my $job_id = $entry->{job_id};

        # If the auditor's test_job_started already populated the
        # running-job entry's pid we missed the cleanup; drop the
        # pending row and move on.
        my $cur = $running_jobs->{$job_id};
        if (!$cur || !$cur->{awaiting_preload_pid}) {
            delete $pending->{$key};
            next;
        }

        warn sprintf(
            "Test2::Harness2: spawn_test request to preload '%s' (%s scope) for job %s timed out after %ds\n",
            $entry->{preload_name}, $entry->{preload_scope}, $job_id, $timeout,
        );

        # Flip the resource to transient broken so the next resolver
        # call defers or routes elsewhere.
        for my $res (@{$h->{Test2::Harness2::RESOURCES()} // []}) {
            next unless blessed($res) && $res->isa('Test2::Harness2::Resource::Preload');
            next unless $res->name  eq $entry->{preload_name};
            next unless $res->scope eq $entry->{preload_scope};
            $res->mark_broken;
            last;
        }

        # Release any committed limiters (jobcount etc.) and drop the
        # placeholder, then return the job to pending so the
        # scheduler picks it up next tick.
        $jt->release_job_resources($cur);
        $jt->take_running_job($job_id);
        $self->{+SCHEDULER}->mark_pending($run_id, $job_id);
        delete $pending->{$key};
    }

    return;
}

# Walk PENDING_PRELOAD_SPAWNS, drop entries older than
# PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS, and re-dispatch via standalone.
# Closes the gap where a grandchild fails to start before sending its
# resource_service_started notification (compile error, fork issue,
# killed before notify, etc.).
sub check_pending_preload_spawn_timeouts {
    my $self = shift;

    my $h = $self->harness or return;

    my $pending  = $self->{+PENDING_PRELOAD_SPAWNS} // {};
    my $deadline = $self->{+PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS} // 30;
    my $now      = time;

    for my $sid (keys %$pending) {
        my $p = $pending->{$sid};
        next if $now - ($p->{sent_at} // $now) < $deadline;

        delete $pending->{$sid};

        my $entry = $p->{entry};
        my $res   = $entry->{resource};

        $h->emit_service_event(
            kind          => 'resource_spawn_preload_timeout',
            resource      => (ref($res) && $res->can('resource_name') ? $res->resource_name : '?'),
            service_class => $entry->{service_class},
            name          => $entry->{name},
            scope         => $entry->{scope} // 'global',
            preload_name  => $p->{preload_name},
            spawn_id      => $sid,
            reason        => "no notification within ${deadline}s",
        );

        my $args = ref($entry->{service_args}) eq 'HASH'
            ? [%{$entry->{service_args}}]
            : ($entry->{service_args} // []);

        $h->_ipcm_service_standalone(
            resource => $res,
            class    => $entry->{service_class},
            args     => $args,
            name     => $entry->{name},
            log_path => $entry->{log_path},
            scope    => $entry->{scope} // 'global',
            (defined $entry->{run} ? (run => $entry->{run}) : ()),
        );
    }

    return;
}

#-------------------------------------------------------------------
# request_handler_list_preloads body. Used by the harness's
# two-line shim. Enumerates the preload services the harness owns
# so the client can dispatch reload requests to each one without
# taking the harness's dispatcher offline. Run-scoped preloads are
# intentionally skipped; reloading a run-scoped preload mid-run
# would invalidate the test state it was built for.
#
# 'name' in the response is the bus-level peer name the caller
# addresses over IPC (preload-<n> for global), not the host-side
# tracking name (which is just <n>). 'preload' is the bare preload
# name for display.
#-------------------------------------------------------------------
sub list {
    my $self = shift;
    my $h = $self->harness or return {ok => 1, preloads => []};

    my $svcs = $h->{Test2::Harness2::RESOURCE_SERVICES()} // {};

    my @out;
    for my $info (values %$svcs) {
        next unless ($info->{service_class} // '') eq 'Test2::Harness2::PreloadService';
        next unless ($info->{scope}         // '') eq 'global';
        next unless defined $info->{pid} && kill 0 => $info->{pid};

        my $res        = $info->{resource};
        my $preload    = (ref($res) && $res->can('name') ? $res->name : ($info->{name} // '?'));
        my $bus_name   = (ref($res) && $res->can('scope'))
            ? $self->peer_name_for_preload($res)
            : "preload-$preload";

        push @out => {
            pid     => $info->{pid},
            name    => $bus_name,
            preload => $preload,
            scope   => $info->{scope},
        };
    }
    return {ok => 1, preloads => \@out};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::PreloadRouter - Preload routing, async spawn watchdogs, and dependent-resource queues for the harness.

=head1 DESCRIPTION

The preload router owns every piece of harness state that is specific
to L<Test2::Harness2::Resource::Preload> resources and the
preload-mediated spawn path:

=over 4

=item *

C<PENDING_SPAWN_REQUESTS> -- the in-flight C<spawn_test> requests sent
to a preload service. Aged each tick; entries past
C<PRELOAD_SPAWN_TIMEOUT_SECS> without a matching C<test_job_started>
flip the preload to transient broken and bounce the job back to
pending.

=item *

C<PENDING_PRELOAD_SPAWNS> -- the in-flight C<spawn_service> requests
sent to a preload service for spawning another resource service. Aged
each tick; entries past C<PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS> without
a matching C<resource_service_started> emit
C<resource_spawn_preload_timeout> and fall back to standalone.

=item *

C<RESOURCES_AWAITING_PRELOAD> -- the queue of dependent resource
services whose preferred preload was configured but had not yet
finished its module-load + C<preload_ready> handshake. Drained on
C<preload_ready>; flushed to standalone on permanent C<preload_broken>.

=item *

C<KNOWN_PRELOAD_NAMES> -- the set of preload names configured for the
harness, populated by L<Test2::Harness2::Role::ResourceServiceHost>.
Used to distinguish "this preload is configured but not yet ready"
(queue + wait) from "no eligible preload and none coming" (fallback
straight to standalone).

=back

The harness constructs one PreloadRouter during its own C<init> and
holds a strong reference to it. The router holds a weakened backref to
the harness via L<Test2::Harness2::Role::Subsystem> so it can reach
the harness's IPC client, the C<RESOURCE_SERVICES> map, the harness
name, the test auditor class, the launch env, and so on.

The harness's C<run_on_interval> calls L</tick> each tick; tick folds
in the L</age_pending_spawn_requests> and
L</check_pending_preload_spawn_timeouts> watchdogs in that order. The
harness's C<run_on_general_message> routes C<preload_ready>,
C<preload_broken>, and C<resource_service_started> kinds to the
matching handler.

=head1 METHODS

=head2 Construction

=over 4

=item $pr = Test2::Harness2::PreloadRouter->new(harness => $h, run_states => $rs, pid_index => $pi, scheduler => $s, job_tracker => $jt)

All ctor args are required. Optional timeout overrides:
C<preload_spawn_timeout_secs> (default 30),
C<preload_service_spawn_timeout_secs> (default 30).

=back

=head2 Per-tick orchestration

=over 4

=item $pr->tick

Folds in L</age_pending_spawn_requests> followed by
L</check_pending_preload_spawn_timeouts> in that order. Called once
per tick from the harness's C<run_on_interval>.

=item $pr->age_pending_spawn_requests

Walk C<PENDING_SPAWN_REQUESTS>; for any entry past
C<preload_spawn_timeout_secs> without a matching C<test_job_started>,
release the placeholder running-job entry, flip the preload to
transient broken, and bounce the job back to pending so the next
scheduler tick can re-attempt.

=item $pr->check_pending_preload_spawn_timeouts

Walk C<PENDING_PRELOAD_SPAWNS>, drop entries older than
C<PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS>, emit
C<resource_spawn_preload_timeout>, and re-dispatch the queued resource
service through the standalone path.

=back

=head2 Resolution

=over 4

=item ($res_or_undef, $kind, $first_name_opt) = $pr->resolve_for_job($run, $job)

Walk the job's preload preference list and decide how to launch it.
See the source for the full decision table.

=back

=head2 Peer-name helpers

=over 4

=item $name = $pr->peer_name_for_preload($preload_resource)

Bus name for a PreloadService: C<preload-E<lt>nE<gt>> for global,
C<preload-E<lt>run_idE<gt>-E<lt>nE<gt>> for run scope.

=item $name = $pr->peer_name_for_resource($entry)

Bus name for a resource service spawned via preload:
C<resource-E<lt>nE<gt>> for global, C<resource-E<lt>run_idE<gt>-E<lt>nE<gt>>
for run scope.

=back

=head2 Lookup

=over 4

=item $info_or_undef = $pr->find_eligible($pname)

Walk the harness's C<RESOURCE_SERVICES> and return the entry for a
live, global-scope, not-permanent_broken PreloadService whose
resource.name matches.

=back

=head2 Spawn

=over 4

=item $pr->spawn_via_preload($run, $job, $preload_resource, %opts)

Send a C<spawn_test> payload to the preload's bus name and install a
pending entry. Rolls back the placeholder running-job entry on dispatch
failure and re-throws.

=item $sid_or_undef = $pr->spawn_service_via_preload($preload_info, $entry)

Send a C<spawn_service> payload to the preload's bus name and install a
pending entry the C<handle_service_started> handler will finalize. Returns
the allocated spawn_id on dispatch success, undef on send failure.

=back

=head2 General-message handlers

=over 4

=item $pr->handle_service_started($content)

Finalize a preload-mediated resource spawn: clear the pending entry,
register the new pid in C<RESOURCE_SERVICES> via
C<track_resource_service>, and emit C<resource_spawn_via_preload>.

=item $pr->handle_preload_state($kind, $content)

Apply C<preload_ready> / C<preload_broken> to the matching
Resource::Preload, then drive the dependent-resource queue via
L</drain_awaiting> or L</fallback_awaiting>.

=back

=head2 Queue drains

=over 4

=item $pr->drain_awaiting($pname)

Drain the wait-for-preload queue for C<$pname> through
L</spawn_service_via_preload>. Entries that are no longer eligible
fall through to the fallback path.

=item $pr->fallback_awaiting($pname)

Flush the wait-for-preload queue for C<$pname> through the standalone
spawn path. Called when the preload reports permanent C<preload_broken>
so dependents still come up, just unpreloaded.

=back

=head2 Request-handler body

=over 4

=item $resp = $pr->list

Body for the harness's C<request_handler_list_preloads> shim:
enumerate global-scope, live PreloadService entries from
C<RESOURCE_SERVICES> and return their bus + tracking names for
operator visibility.

=back

=head2 Inherited

=over 4

=item $h = $pr->harness

Returns the harness reference, or C<undef> when the harness has gone
away. Inherited from L<Test2::Harness2::Role::Subsystem>.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::Resource::Preload>, L<Test2::Harness2::PreloadService>,
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
