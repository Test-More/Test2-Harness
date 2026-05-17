use strict;
use warnings;

use Test2::V0;

use Scalar::Util ();
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Test2::Harness2::Resource::Preload;

# --- helpers --------------------------------------------------------------

# Build a tiny harness + router pair. The harness is a bare hashref
# blessed into Test2::Harness2 (no real ipc bus); the router has the
# slots resolve_for_job + the watchdog need.
sub make_pair {
    my %harness_extra = @_;
    my $h = bless {
        resources         => [],
        resource_services => {},
        name              => 'harness',
        %harness_extra,
    }, 'Test2::Harness2';

    my $router = bless {
        harness                            => $h,
        pending_spawn_requests             => {},
        pending_preload_spawns             => {},
        resources_awaiting_preload         => {},
        known_preload_names                => {},
        preload_spawn_timeout_secs         => 30,
        preload_service_spawn_timeout_secs => 30,
    }, 'Test2::Harness2::PreloadRouter';
    Scalar::Util::weaken($router->{harness});
    $h->{preload_router} = $router;
    return ($h, $router);
}

sub make_preload {
    my %args = @_;
    my $r = Test2::Harness2::Resource::Preload->new(
        name             => $args{name},
        modules          => $args{modules} // [],
        scope            => $args{scope}   // 'global',
        ($args{scope} && $args{scope} eq 'run'
            ? (run => bless { run_id => $args{run_id} // 'R1' }, 'PRTFakeRun')
            : ()),
        is_role_consumer => $args{is_role_consumer} // 0,
    );
    $r->mark_ready                if $args{usable};
    $r->mark_broken               if $args{transient_broken};
    $r->mark_permanent_broken     if $args{permanent_broken};
    return $r;
}

sub make_run {
    my $rid = shift // 'R1';
    return bless { run_id => $rid }, 'PRTFakeRun';
}

sub make_job {
    my @prefs = @_;
    my $tf = bless { _prefs => [@prefs] }, 'PRTFakeTestFile';
    return bless { test_file => $tf }, 'PRTFakeJob';
}

{
    no strict 'refs';
    *PRTFakeRun::run_id    = sub { $_[0]->{run_id} };
    *PRTFakeRun::resources = sub { $_[0]->{resources} // [] };
    *PRTFakeTestFile::preload_preferences = sub { $_[0]->{_prefs} };
    *PRTFakeJob::test_file = sub { $_[0]->{test_file} };
    *PRTFakeJob::job_id    = sub { $_[0]->{job_id} // 'J1' };
    *PRTFakeJob::job_try   = sub { 1 };
    *PRTFakeJob::test_file_abs = sub { '/tmp/t.t' };
}

# --- resolve_for_job ------------------------------------------------------

subtest 'resolve_for_job: <no> short-circuits to no_preload' => sub {
    my ($h, $router) = make_pair();
    my @r = $router->resolve_for_job(make_run(), make_job('<no>'));
    is(\@r, [undef, 'no_preload'], '<no> resolves immediately');
};

subtest 'resolve_for_job: usable global named match' => sub {
    my $preload = make_preload(name => 'foo', usable => 1);
    my ($h, $router) = make_pair(resources => [$preload]);
    my @r = $router->resolve_for_job(make_run(), make_job('foo'));
    is(\@r, [$preload, 'preload'], 'usable returns preload kind');
};

subtest 'resolve_for_job: transient broken defers' => sub {
    my $preload = make_preload(name => 'foo', transient_broken => 1);
    my ($h, $router) = make_pair(resources => [$preload]);
    my @r = $router->resolve_for_job(make_run(), make_job('foo'));
    is(\@r, [undef, 'defer'], 'defer status');
};

subtest 'resolve_for_job: permanent broken + no fallback = broken' => sub {
    my $preload = make_preload(name => 'foo', permanent_broken => 1);
    my ($h, $router) = make_pair(resources => [$preload]);
    my @r = $router->resolve_for_job(make_run(), make_job('foo'));
    is(\@r, [undef, 'broken', 'foo'], 'broken + first name');
};

subtest 'resolve_for_job: <default> resolves global role-consumer' => sub {
    my $only = make_preload(name => 'OnlyOne', is_role_consumer => 1, usable => 1);
    my ($h, $router) = make_pair(resources => [$only]);
    my @r = $router->resolve_for_job(make_run(), make_job('<default>'));
    is(\@r, [$only, 'preload'], 'single role consumer is global default');
};

subtest 'resolve_for_job: per-run preload wins over global by name' => sub {
    my $global = make_preload(name => 'foo', scope => 'global', usable => 1);
    my $perrun = make_preload(name => 'foo', scope => 'run', run_id => 'R1', usable => 1);
    my ($h, $router) = make_pair(resources => [$global, $perrun]);
    my @r = $router->resolve_for_job(make_run('R1'), make_job('foo'));
    is($r[0], $perrun, 'per-run preferred over global');
};

# --- peer-name helpers ----------------------------------------------------

subtest 'peer_name_for_resource: global + run scopes' => sub {
    is(
        Test2::Harness2::PreloadRouter->peer_name_for_resource(
            {name => 'svc', scope => 'global'},
        ),
        'resource-svc',
        'global scope',
    );
    is(
        Test2::Harness2::PreloadRouter->peer_name_for_resource(
            {name => 'svc', scope => 'run', run => 'RID'},
        ),
        'resource-RID-svc',
        'run scope with run_id',
    );
    is(
        Test2::Harness2::PreloadRouter->peer_name_for_resource(
            {name => 'svc', scope => 'run'},
        ),
        'resource-svc',
        'run scope without run_id falls back to global form',
    );
};

subtest 'peer_name_for_preload: global + run scopes' => sub {
    my $g = make_preload(name => 'p1', scope => 'global');
    is(
        Test2::Harness2::PreloadRouter->peer_name_for_preload($g),
        'preload-p1',
        'global scope',
    );
    my $r = make_preload(name => 'p2', scope => 'run', run_id => 'R7');
    is(
        Test2::Harness2::PreloadRouter->peer_name_for_preload($r),
        'preload-R7-p2',
        'run scope includes run_id',
    );
};

# --- tick + watchdogs -----------------------------------------------------

subtest 'tick: pending-spawn watchdog times out + flips preload broken' => sub {
    my $preload = make_preload(name => 'p1', usable => 1);
    my ($h, $router) = make_pair(resources => [$preload]);
    $router->{preload_spawn_timeout_secs} = 0;

    # Fake JobTracker + Scheduler that the watchdog calls into.
    my @released; my @taken; my @bounced;
    my $jt = bless {
        running_jobs => {
            J1 => {
                pid                  => undef,
                awaiting_preload_pid => 1,
                preload_name         => 'p1',
                preload_scope        => 'global',
                started_at           => time,
                assign_id            => 'A1',
                assigned_resources   => [],
            },
        },
    }, 'PRTFakeJT';
    {
        no strict 'refs';
        *PRTFakeJT::running_jobs           = sub { $_[0]->{running_jobs} };
        *PRTFakeJT::release_job_resources  = sub { push @released, $_[1] };
        *PRTFakeJT::take_running_job       = sub { push @taken, $_[1]; delete $_[0]->{running_jobs}{$_[1]} };
    }
    my $sch = bless {}, 'PRTFakeSch';
    {
        no strict 'refs';
        *PRTFakeSch::mark_pending = sub { push @bounced, [$_[1], $_[2]] };
    }

    $router->{job_tracker} = $jt;
    $router->{scheduler}   = $sch;

    # Backdate a pending spawn request so the watchdog fires.
    $router->{pending_spawn_requests}{"R1\0J1"} = {
        run_id        => 'R1',
        job_id        => 'J1',
        sent_at       => time - 60,
        preload_name  => 'p1',
        preload_scope => 'global',
    };

    local $SIG{__WARN__} = sub { };
    $router->tick;

    ok(!$router->{pending_spawn_requests}{"R1\0J1"}, 'pending dropped');
    is(\@taken,    ['J1'],            'placeholder taken');
    is(\@bounced,  [['R1', 'J1']],    'job bounced to pending');
    ok($preload->is_broken,            'preload flipped transient broken');
    ok(!$preload->is_permanent_broken, 'not permanent');
};

# --- drain_awaiting -------------------------------------------------------

subtest 'drain_awaiting: empty queue is a no-op' => sub {
    my ($h, $router) = make_pair();
    is($router->drain_awaiting('nothing'), undef, 'returns undef on missing key');
};

subtest 'drain_awaiting: dispatches via spawn_service_via_preload when eligible' => sub {
    my ($h, $router) = make_pair();

    my @spawned;
    {
        no warnings 'redefine';
        local *Test2::Harness2::PreloadRouter::spawn_service_via_preload = sub {
            my (undef, $pinfo, $entry) = @_;
            push @spawned, [$pinfo->{name}, $entry->{name}];
            return 99;
        };
        local *Test2::Harness2::PreloadRouter::find_eligible = sub {
            my (undef, $pname) = @_;
            return $pname eq 'p1' ? {name => 'preload-p1', pid => $$} : undef;
        };

        push @{$router->{resources_awaiting_preload}{p1}} => {
            name          => 'svc',
            scope         => 'global',
            service_class => 'X',
            service_args  => {},
            resource      => bless({}, 'X'),
            log_path      => '/tmp/p',
        };

        $router->drain_awaiting('p1');
    }

    is(scalar @spawned, 1,                    'spawn_service_via_preload called once');
    is($spawned[0],     ['preload-p1', 'svc'], 'dispatched the queued entry');
    is(scalar @{$router->{resources_awaiting_preload}{p1} // []}, 0,
        'queue emptied');
};

done_testing;
