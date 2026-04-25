use Test2::V0;

# Use the production TestFile from lib/ (not the t/lib stub) so that
# check_feature('preload') returns the %DEFAULTS value of 1 when the
# feature is not explicitly set -- the stub version has no defaults.
use Test2::Harness2::TestFile;
use Test2::Harness2::Run::Job;
use Test2::Harness2::Resource::Preload;

# Fake preload module with one named stage for routing tests.
{
    package My::Resource::Test::StagePreload;
    use Test2::Harness2::Preload;
    stage 'Alpha' => sub {};
}
$INC{'My/Resource/Test/StagePreload.pm'} = 1;

sub make_job {
    my (%tf_attrs) = @_;
    my $tf = Test2::Harness2::TestFile->new(file => 't/x.t', %tf_attrs);
    return Test2::Harness2::Run::Job->new(test_file => $tf, run_id => 'r');
}

subtest 'construction with empty preloads' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    ok($r, 'constructed without error');
    is($r->resource_name, 'preload', 'resource_name is "preload"');
};

subtest 'consumes Role::Resource' => sub {
    require Role::Tiny;
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    ok(
        Role::Tiny::does_role($r, 'Test2::Harness2::Role::Resource'),
        'Preload consumes Role::Resource',
    );
};

subtest 'is_job_limiter is false' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    ok(!$r->is_job_limiter, 'not a job limiter');
};

subtest 'needed: returns 1 by default, 0 when preload feature disabled' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);

    my $j_default  = make_job();
    my $j_disabled = make_job(features => {preload => 0});

    is($r->needed(job => $j_default),  1, 'needed=1 when preload is enabled (default)');
    is($r->needed(job => $j_disabled), 0, 'needed=0 when preload explicitly disabled');
};

subtest 'available: defers while stage is pending, grants when up' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    my $j = make_job();

    is($r->available(job => $j), 0, 'available=0 while stage is pending');

    $r->set_stage_up('preload-root');
    is($r->available(job => $j), 1, 'available=1 after stage comes up');
};

subtest 'assign and release bookkeeping' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    $r->set_stage_up('preload-root');

    my $j = make_job();
    is($r->assign(id => 'x1', job => $j), 1, 'assign returns 1');

    ok(exists $r->{'job_stages'}{'x1'}, 'job_stages entry created');
    is($r->{'job_stages'}{'x1'}, 'preload-root', 'job mapped to preload-root stage');

    $r->release(id => 'x1');
    ok(!exists $r->{'job_stages'}{'x1'}, 'job_stages entry removed after release');
};

subtest 'duplicate assign id is rejected' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    $r->set_stage_up('preload-root');
    my $j = make_job();
    $r->assign(id => 'dup', job => $j);
    my $ok = eval { $r->assign(id => 'dup', job => $j); 1 };
    ok(!$ok, 'second assign with same id dies');
    like($@, qr/duplicate assign/, 'error mentions "duplicate assign"');
};

subtest 'services() returns single PreloadRoot entry with correct keys' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        preloads     => ['Scalar::Util'],
        preload_early => {SomeModule => [1]},
        harness_name  => 'test-harness',
    );

    my @svc = $r->services;
    is(scalar @svc, 1, 'one service entry');

    my ($class, %args) = @{$svc[0]};
    is($class, 'Test2::Harness2::ResourceService::PreloadRoot', 'correct service class');
    is($args{name},         'preload-root',      'name is preload-root');
    is($args{harness_name}, 'test-harness',      'harness_name forwarded');
    is($args{preloads},     ['Scalar::Util'],    'preloads forwarded');
    ok(exists $args{preload_early},              'preload_early forwarded');
};

subtest 'status reports stage states and health flags' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    my $s = $r->status;
    is($s->{resource},  'preload', 'resource key present');
    is($s->{broken},    0,         'not broken initially');
    is($s->{paused},    0,         'not paused initially');
    is($s->{permanent}, 0,         'not permanently broken initially');
    ok(exists $s->{stages}{'preload-root'}, 'preload-root in stages');
    is($s->{stages}{'preload-root'}, 'pending', 'initial state is pending');
};

subtest 'set_stage_up / set_stage_down transitions' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    is($r->status->{stages}{'preload-root'}, 'pending', 'starts pending');

    $r->set_stage_up('preload-root');
    is($r->status->{stages}{'preload-root'}, 'up', 'up after set_stage_up');

    $r->set_stage_down('preload-root');
    is($r->status->{stages}{'preload-root'}, 'down', 'down after set_stage_down');
};

subtest 'brokenness / paused states' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    ok($r->is_usable, 'usable when healthy');

    $r->mark_broken;
    ok($r->is_broken,   'broken after mark_broken');
    ok(!$r->is_usable,  'not usable when broken');

    $r->mark_resumed;
    ok(!$r->is_broken,  'no longer broken after mark_resumed');
    ok($r->is_usable,   'usable after mark_resumed');

    $r->mark_paused;
    ok($r->is_paused,   'paused after mark_paused');
    ok(!$r->is_usable,  'not usable when paused');

    $r->mark_resumed;
    ok(!$r->is_paused,  'not paused after mark_resumed');
};

subtest 'mark_permanent_broken survives mark_resumed' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    $r->mark_permanent_broken;
    ok($r->is_broken,           'broken after mark_permanent_broken');
    ok($r->is_permanent_broken, 'permanent_broken set');

    $r->mark_resumed;
    ok($r->is_permanent_broken, 'permanent_broken survives resume');
    ok($r->is_broken,           'is_broken persists too (set by permanent_broken)');
};

subtest 'stage_handle_for_job returns undef without ipcm_info' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    $r->set_stage_up('preload-root');
    my $j = make_job();
    is($r->stage_handle_for_job($j), undef, 'undef when ipcm_info not set');
};

subtest '_stage_for_job routes to named stage when job check_stage matches' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        preloads => ['My::Resource::Test::StagePreload'],
    );

    # Stage 'Alpha' is in the stage tree; bring it up so available() returns 1.
    $r->set_stage_up('Alpha');

    my $j_alpha = make_job(stage => 'Alpha');
    is($r->available(job => $j_alpha), 1, 'available=1 for job routed to named stage Alpha');

    $r->assign(id => 's1', job => $j_alpha);
    is($r->{'job_stages'}{'s1'}, 'Alpha', 'job assigned to Alpha stage');
};

subtest '_stage_for_job falls back to preload-root when requested stage is unknown' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(preloads => []);
    $r->set_stage_up('preload-root');

    # 'Nonexistent' is not in the stage_states; should fall back to preload-root.
    my $j = make_job(stage => 'Nonexistent');
    is($r->available(job => $j), 1, 'available=1 after falling back to preload-root');

    $r->assign(id => 'fb1', job => $j);
    is($r->{'job_stages'}{'fb1'}, 'preload-root', 'fallback job assigned to preload-root');
};

subtest '_stage_for_job uses default stage from tree when no stage requested' => sub {
    my $r = Test2::Harness2::Resource::Preload->new(
        preloads => ['My::Resource::Test::StagePreload'],
    );

    # Alpha is the first (and only) stage, so it becomes the implicit default.
    $r->set_stage_up('Alpha');

    my $j = make_job();    # no stage preference
    is($r->available(job => $j), 1, 'available=1 routed to tree default stage Alpha');

    $r->assign(id => 'def1', job => $j);
    is($r->{'job_stages'}{'def1'}, 'Alpha', 'default-routed job assigned to Alpha');
};

done_testing;
