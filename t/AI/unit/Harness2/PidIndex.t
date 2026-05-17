use strict;
use warnings;

use Test2::V0;

use Time::HiRes ();

use Test2::Harness2::PidIndex;

my $RUN_A = '11111111-1111-1111-1111-111111111111';
my $RUN_B = '22222222-2222-2222-2222-222222222222';

# Bare PidIndex with no harness backref: pure-data subsystem mode. This
# is the simplest exercise of the moved code.

subtest register_and_lookup => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    $pi->register($RUN_A, 1001, kind => 'collector', job_id => 'j1');
    $pi->register($RUN_A, 1002, kind => 'collector', job_id => 'j2');
    $pi->register($RUN_B, 2001, kind => 'collector', job_id => 'j3');

    is(
        [sort { $a <=> $b } $pi->pids_for_run($RUN_A)],
        [1001, 1002],
        'pids_for_run isolates by run',
    );
    is([$pi->pids_for_run($RUN_B)], [2001], 'run B sees its own pid only');
    is([$pi->pids_for_run('does-not-exist')], [], 'unknown run returns empty');

    my ($run_key, $meta) = $pi->run_for_pid(1002);
    is($run_key, $RUN_A, 'run_for_pid resolves run');
    is($meta->{kind}, 'collector', 'meta carries kind');
    is($meta->{job_id}, 'j2', 'meta carries job_id');
    ok($meta->{started_at}, 'started_at auto-stamped');

    is([$pi->run_for_pid(9999)], [undef, undef], 'unknown pid returns (undef,undef)');
};

subtest register_guards => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    is($pi->register(undef, 1234), undef, 'undef run_key rejected');
    is($pi->register('', 1234),    undef, 'empty run_key rejected');
    is($pi->register($RUN_A, 0),   undef, 'pid 0 rejected');
    is($pi->register($RUN_A, -1),  undef, 'negative pid rejected');
    is([$pi->pids_for_run($RUN_A)], [], 'nothing was actually recorded');
};

subtest forget_drops_empty_bucket => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    $pi->register($RUN_A, 1001, kind => 'collector');
    $pi->register($RUN_A, 1002, kind => 'collector');

    my $meta = $pi->forget($RUN_A, 1001);
    is($meta->{kind}, 'collector', 'forget returns the dropped meta');
    ok(exists $pi->{run_pids}{$RUN_A}, 'bucket retained while still populated');

    $pi->forget($RUN_A, 1002);
    ok(!exists $pi->{run_pids}{$RUN_A}, 'bucket removed when last pid leaves');

    is($pi->forget($RUN_A, 9999),       undef, 'forget on missing pid is a no-op');
    is($pi->forget('no-such-run', 1),   undef, 'forget on missing run is a no-op');
    is($pi->forget(undef, 1),           undef, 'forget on undef run is a no-op');
};

subtest kill_run_isolation => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    # $$ is a live pid; signal 0 is a liveness probe so this neither
    # signals ourselves harmfully nor leaks a child.
    $pi->register($RUN_A, $$, kind => 'collector');
    $pi->register($RUN_B, 999_999, kind => 'collector');

    my $sent = $pi->kill_run($RUN_A, 0);
    is($sent, 1, 'kill_run delivered to live pid in run A');

    $sent = $pi->kill_run($RUN_B, 0);
    is($sent, 0, 'kill_run skips dead pid in run B');

    is($pi->kill_run('no-such-run', 0), 0, 'kill_run on empty run returns 0');
};

subtest await_run_exit_timeout => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    $pi->register($RUN_A, 99_998, kind => 'collector');
    my $start  = Time::HiRes::time();
    my $ok     = $pi->await_run_exit($RUN_A, $start + 0.1);
    my $waited = Time::HiRes::time() - $start;

    is($ok, 0, 'await returns 0 on deadline');
    ok($waited >= 0.05, 'waited at least to the deadline');
    ok($waited < 1.5,   'did not block much beyond the deadline');

    $pi->forget($RUN_A, 99_998);
    is($pi->await_run_exit($RUN_A, Time::HiRes::time() + 5), 1,
        'await returns 1 immediately when run is empty');
};

subtest await_run_exit_default_deadline_with_harness => sub {
    # Fake harness exposing kill_timeout so await_run_exit's default
    # deadline path is exercised. The bucket is already empty so the
    # call returns 1 immediately without invoking tinysleep.
    my $fake = bless { kill_timeout => 5 }, 'TestFakeHarness';
    my $pi   = Test2::Harness2::PidIndex->new(harness => $fake);

    is($pi->await_run_exit($RUN_A), 1,
        'await with default deadline returns 1 for empty run');

    package TestFakeHarness;
    sub kill_timeout { $_[0]->{kill_timeout} }
};

subtest resource_service_hooks_register => sub {
    my $pi = Test2::Harness2::PidIndex->new;

    # No harness bound -> the resource_services lookup short-circuits
    # and the tracked entry has no inherited started_at.
    my $fake_resource = bless { resource_name => 'jobcount' }, 'TestFakeResource';

    $pi->resource_service_tracked(
        pid      => 4321,
        scope    => 'global',
        run      => undef,
        name     => 'jobcount',
        resource => $fake_resource,
    );

    my ($run_key, $meta) = $pi->run_for_pid(4321);
    is($run_key, '__global__',
        'global resource service registered under __global__ key');
    is($meta->{kind},     'resource_service', 'kind tagged');
    is($meta->{res_svc},  'jobcount',         'service name carried');
    is($meta->{res_name}, 'jobcount',         'resource name carried');
    is($meta->{scope},    'global',           'scope carried');

    my $fake_run = bless { run_id => $RUN_A }, 'TestFakeRun';
    $pi->resource_service_tracked(
        pid      => 5678,
        scope    => 'run',
        run      => $fake_run,
        name     => 'percpu',
        resource => $fake_resource,
    );
    ($run_key) = $pi->run_for_pid(5678);
    is($run_key, $RUN_A, 'per-run resource service keyed by run_id');

    $pi->resource_service_forgotten(
        pid   => 4321,
        scope => 'global',
        run   => undef,
        name  => 'jobcount',
    );
    is([$pi->run_for_pid(4321)], [undef, undef], 'global service forgotten');

    $pi->resource_service_forgotten(
        pid   => 5678,
        scope => 'run',
        run   => $fake_run,
        name  => 'percpu',
    );
    is([$pi->run_for_pid(5678)], [undef, undef], 'per-run service forgotten');

    package TestFakeResource;
    sub resource_name { $_[0]->{resource_name} }

    package TestFakeRun;
    sub run_id { $_[0]->{run_id} }
};

subtest resource_service_tracked_inherits_started_at => sub {
    # When a harness is bound and its resource_services map already has
    # an entry for the pid (which is the normal sequence:
    # Role::ResourceServiceHost records the entry first, then notifies),
    # the tracked entry should adopt the existing started_at.
    my $fake = bless {
        resource_services => { 7777 => { started_at => 123 } },
    }, 'TestHarnessWithRS';
    sub TestHarnessWithRS::resource_services { $_[0]->{resource_services} }
    sub TestHarnessWithRS::kill_timeout      { 15 }

    my $pi = Test2::Harness2::PidIndex->new(harness => $fake);
    my $fake_resource = bless { resource_name => 'svc' }, 'TestFakeResource2';
    sub TestFakeResource2::resource_name { $_[0]->{resource_name} }

    $pi->resource_service_tracked(
        pid      => 7777,
        scope    => 'global',
        name     => 'svc',
        resource => $fake_resource,
    );

    my (undef, $meta) = $pi->run_for_pid(7777);
    is($meta->{started_at}, 123, 'started_at inherited from harness resource_services entry');
};

subtest clear_drops_everything => sub {
    my $pi = Test2::Harness2::PidIndex->new;
    $pi->register($RUN_A, 1, kind => 'collector');
    $pi->register($RUN_B, 2, kind => 'collector');
    $pi->clear;
    is([$pi->pids_for_run($RUN_A)], [], 'run A drained');
    is([$pi->pids_for_run($RUN_B)], [], 'run B drained');
    is($pi->{run_pids}, {}, 'underlying map is empty');
};

done_testing;
