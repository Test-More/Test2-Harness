use Test2::V0;

use File::Temp qw/tempdir/;

use Test2::Harness2::Resource::Preload;

# Test-only fakes for the assign path (kept at the top so Test2::V0
# exports remain in main:: when the subtests run).
{

    package FakeJob;
    sub new       { my ($class, %p) = @_; bless \%p, $class }
    sub test_file { $_[0]->{test_file} }
}

{

    package FakeTF;
    sub new      { my ($class, %p) = @_; bless \%p, $class }
    sub relative { $_[0]->{relative} }
}

my $wd = tempdir(CLEANUP => 1);

subtest 'construction basics' => sub {
    like(
        dies { Test2::Harness2::Resource::Preload->new() },
        qr/'workdir' is a required attribute/,
        'workdir is required',
    );

    like(
        dies { Test2::Harness2::Resource::Preload->new(workdir => '/no/such/path/plz') },
        qr/must point at an existing directory/,
        'workdir must exist',
    );

    like(
        dies { Test2::Harness2::Resource::Preload->new(workdir => $wd, preload => 'not-array') },
        qr/'preload' must be an arrayref/,
        'preload must be an arrayref',
    );

    my $r = Test2::Harness2::Resource::Preload->new(
        workdir => $wd,
        preload => ['Scalar::Util', 'List::Util'],
    );

    is($r->resource_name,                                'preload',                      'resource_name');
    is($r->is_job_limiter,                               0,                              'not a job limiter');
    is($r->preload,                                      ['Scalar::Util', 'List::Util'], 'preload list captured');
    is($r->service_preload_applicable(harness => undef), 1,                              'applicable with modules');
    is($r->service_preload_restartable,                  0,                              'not restartable in Stage 8');
};

subtest 'applicability gates empty preloads' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        workdir => $wd,
        preload => [],
    );

    is(
        $r->service_preload_applicable(harness => undef), 0,
        'empty preload list => service is skipped'
    );
};

subtest 'Role::Resource contract methods' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        workdir => $wd,
        preload => ['Scalar::Util'],
    );

    is($r->available, 1, 'available never gates');
    is($r->release,   1, 'release is a no-op');

    # Status shape reports what the service would look like.
    my $s = $r->status;
    is($s->{resource},     'preload',        'status: resource');
    is($s->{service_name}, 'preload',        'status: service_name default');
    is($s->{preload},      ['Scalar::Util'], 'status: preload list');
    is($s->{broken},       0,                'status: broken=0');
    is($s->{paused},       0,                'status: paused=0');
    is($s->{permanent},    0,                'status: permanent=0');

    # Broken-state transitions.
    $r->mark_paused;
    is($r->is_paused, 1, 'paused transition');
    $r->mark_resumed;
    is($r->is_paused, 0, 'resumed');

    $r->mark_permanent_broken;
    is($r->is_broken,           1, 'permanent-broken implies broken');
    is($r->is_permanent_broken, 1, 'permanent-broken');
};

subtest 'assign stamps env when stage known' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        workdir       => $wd,
        preload       => ['Scalar::Util'],
        default_stage => 'main',
    );

    my $tf  = FakeTF->new(relative => 't/x.t');
    my $job = FakeJob->new(test_file => $tf);

    my %env;
    $r->assign(job => $job, env => \%env, id => 'x');
    is($env{T2_HARNESS_PRELOAD_STAGE}, 'main', 'assigned stage written to env');
};

done_testing;
