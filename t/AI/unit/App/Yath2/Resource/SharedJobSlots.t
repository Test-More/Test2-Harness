use Test2::V0;
use Cwd qw/abs_path/;
use File::Temp qw/tempdir/;
use YAML::Tiny;

BEGIN {
    # Keep @INC absolute so the resource's deferred require of
    # ::State resolves after we chdir into a fixture tmpdir.
    @INC = map { ref($_) ? $_ : abs_path($_) // $_ } @INC;
}

use App::Yath2::Resource::SharedJobSlots;

my $CLASS = 'App::Yath2::Resource::SharedJobSlots';

# Build a tiny YAML config in $dir and return the path.
sub build_config {
    my ($dir, %overrides) = @_;

    my $state_file = $overrides{state_file} // "$dir/state.json";

    my $yaml = {
        COMMON => {
            state_file        => $state_file,
            max_slots         => $overrides{max_slots}         // 4,
            max_slots_per_job => $overrides{max_slots_per_job} // 2,
            max_slots_per_run => $overrides{max_slots_per_run} // 4,
        },
        DEFAULT => {
            no_warning => 1,
        },
    };

    my $path = "$dir/.sharedjobslots.yml";
    YAML::Tiny->new($yaml)->write($path);

    return $path;
}

# Minimal job-like object satisfying _job_concurrency: any test_file
# with min_slots/max_slots accessors will do.
package FakeTestFile {
    sub new {
        my ($class, %p) = @_;
        return bless {%p}, $class;
    }
    sub min_slots { $_[0]->{min_slots} // 1 }
    sub max_slots { $_[0]->{max_slots} // 0 }
    sub relative  { $_[0]->{relative} }
    sub file      { $_[0]->{file} }
}
package FakeJob {
    sub new {
        my ($class, %p) = @_;
        return bless {%p}, $class;
    }
    sub test_file { $_[0]->{test_file} }
}

subtest 'construction requires slots + existing config' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = build_config($dir);

    like(
        dies { $CLASS->new(slots => 0, shared_jobs_config => $cfg) },
        qr/'slots' is a required attribute/,
        "slots=0 rejected"
    );

    like(
        dies { $CLASS->new(slots => 2, shared_jobs_config => "$dir/missing.yml") },
        qr/Could not find shared jobs config/,
        "missing config rejected"
    );

    my $r = $CLASS->new(slots => 2, shared_jobs_config => $cfg);
    isa_ok($r, [$CLASS], "constructed");
    is($r->resource_name,   'sharedjobslots', "resource_name");
    is($r->is_job_limiter,  1,                "is_job_limiter true");
};

subtest 'available / assign / release' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = build_config($dir, max_slots => 6, max_slots_per_job => 3);

    my $r = $CLASS->new(
        slots              => 4,
        job_slots          => 2,
        shared_jobs_config => $cfg,
        runner_id          => 'unit-one',
    );

    my $job = FakeJob->new(test_file => FakeTestFile->new(
        min_slots => 1,
        max_slots => 2,
        relative  => 't/fake.t',
    ));

    my $granted = $r->available(id => 'j1', job => $job);
    ok($granted > 0, "available returned >0 (got $granted)");

    my $env = {};
    my $assigned = $r->assign(id => 'j1', job => $job, env => $env);
    is($assigned, $granted, "assigned count matches granted");
    is($env->{T2_HARNESS_MY_JOB_CONCURRENCY}, $granted, "T2_HARNESS_MY_JOB_CONCURRENCY stamped");

    $r->release(id => 'j1', job => $job);

    my $status = $r->status;
    is($status->{resource},   'sharedjobslots', "status.resource");
    is($status->{slots},      4,                "status.slots");
    is($status->{job_slots},  2,                "status.job_slots");
};

subtest 'min > max returns -1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = build_config($dir, max_slots => 2, max_slots_per_job => 2);

    my $r = $CLASS->new(
        slots              => 2,
        job_slots          => 1,
        shared_jobs_config => $cfg,
        runner_id          => 'unit-impossible',
    );

    my $job = FakeJob->new(test_file => FakeTestFile->new(
        min_slots => 8,     # bigger than every cap
        max_slots => 8,
        relative  => 't/impossible.t',
    ));

    is($r->available(id => 'j1', job => $job), -1, "impossible job skipped (-1)");
};

subtest 'observe mode' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = build_config($dir);

    my $r = $CLASS->new(
        slots              => 2,
        shared_jobs_config => $cfg,
        runner_id          => 'unit-obs',
        observe            => 1,
    );

    my $job = FakeJob->new(test_file => FakeTestFile->new(
        min_slots => 1,
        max_slots => 1,
        relative  => 't/obs.t',
    ));

    # available still runs; assign is a no-op under observe.
    my $granted = $r->available(id => 'j1', job => $job);
    ok($granted > 0, "available works in observe mode");

    my $env = {};
    my $assigned = $r->assign(id => 'j1', job => $job, env => $env);
    ok(!defined $assigned, "assign returns undef in observe mode");
    ok(!exists $env->{T2_HARNESS_MY_JOB_CONCURRENCY}, "env not touched in observe mode");

    # release is a no-op too.
    $r->release(id => 'j1', job => $job);

    pass("no crash in observe mode");
};

subtest 'broken / paused transitions' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cfg = build_config($dir);

    my $r = $CLASS->new(
        slots              => 1,
        shared_jobs_config => $cfg,
        runner_id          => 'unit-br',
    );

    ok(!$r->is_broken,           "not broken initially");
    ok(!$r->is_paused,           "not paused initially");
    ok(!$r->is_permanent_broken, "not permanent broken initially");

    $r->mark_broken;
    ok($r->is_broken, "marked broken");
    ok(!$r->is_usable, "unusable once broken");

    $r->mark_resumed;
    ok(!$r->is_broken, "resumed clears broken");

    $r->mark_paused;
    ok($r->is_paused, "paused");
    $r->mark_resumed;
    ok(!$r->is_paused, "resumed clears paused");

    $r->mark_permanent_broken;
    ok($r->is_permanent_broken, "marked permanent broken");
    ok($r->is_broken,           "permanent broken implies broken");
};

done_testing;
