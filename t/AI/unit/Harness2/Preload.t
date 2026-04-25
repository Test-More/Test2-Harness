use Test2::V0;

use Test2::Harness2::Preload;
use Test2::Harness2::Preload::Stage;

# Each package installs DSL via 'use' at compile time; the stage() calls
# below run at file-load time (before any subtest).

{   package My::Preload::One;
    use Test2::Harness2::Preload;
    stage 'Alpha' => sub { preload 'Scalar::Util'; }; }

{   package My::Preload::Two;
    use Test2::Harness2::Preload;
    stage 'Foo' => sub {};
    stage 'Bar' => sub {}; }

{   package My::Preload::Nested;
    use Test2::Harness2::Preload;
    stage 'Root' => sub { stage 'Child' => sub {}; }; }

{   package My::Preload::ExplicitDefault;
    use Test2::Harness2::Preload;
    stage 'First'  => sub {};
    stage 'Second' => sub { default(); }; }

{   package My::Preload::ImplicitDefault;
    use Test2::Harness2::Preload;
    stage 'Alpha' => sub {};
    stage 'Beta'  => sub {}; }

{   package My::Preload::Eager;
    use Test2::Harness2::Preload;
    stage 'EagerStage' => sub { eager(); };
    stage 'QuietStage' => sub {}; }

{   package My::Preload::DupFirst;
    use Test2::Harness2::Preload;
    stage 'Dup' => sub {}; }   # first registration; second call in subtest should croak

{   package My::Preload::BadCode;
    use Test2::Harness2::Preload; }    # no stages yet; used for error-propagation test

{   package My::Preload::MergeA;
    use Test2::Harness2::Preload;
    stage 'StageA' => sub {}; }

{   package My::Preload::MergeB;
    use Test2::Harness2::Preload;
    stage 'StageB' => sub {}; }

# ---------------------------------------------------------------------------

subtest 'TEST2_HARNESS_PRELOAD returns the Preload instance' => sub {
    my $p = My::Preload::One::TEST2_HARNESS_PRELOAD();
    isa_ok($p, 'Test2::Harness2::Preload');
};

subtest 'exports land in caller namespace' => sub {
    for my $name (qw/ TEST2_HARNESS_PRELOAD stage preload eager default
                      pre_fork post_fork pre_launch watch reload_inplace_check /) {
        ok(My::Preload::One->can($name), "$name exported");
    }
};

subtest 'stage_list and stage_lookup reflect top-level stages' => sub {
    my $p = My::Preload::Two::TEST2_HARNESS_PRELOAD();
    is(scalar @{$p->stage_list}, 2, 'two top-level stages');
    is($p->stage_list->[0]->name, 'Foo', 'first stage is Foo');
    is($p->stage_list->[1]->name, 'Bar', 'second stage is Bar');
    ok(exists $p->stage_lookup->{Foo}, 'Foo in lookup');
    ok(exists $p->stage_lookup->{Bar}, 'Bar in lookup');
};

subtest 'nested stage goes into lookup but not top-level list' => sub {
    my $p = My::Preload::Nested::TEST2_HARNESS_PRELOAD();
    is(scalar @{$p->stage_list}, 1, 'one top-level stage');
    ok(exists $p->stage_lookup->{Root},  'Root in lookup');
    ok(exists $p->stage_lookup->{Child}, 'Child also in lookup');
};

subtest 'explicit default_stage' => sub {
    my $p = My::Preload::ExplicitDefault::TEST2_HARNESS_PRELOAD();
    is($p->default_stage, 'Second', 'explicit default_stage is Second');
};

subtest 'implicit default_stage falls back to first stage' => sub {
    my $p    = My::Preload::ImplicitDefault::TEST2_HARNESS_PRELOAD();
    my $ds   = $p->default_stage;
    my $name = ref($ds) ? $ds->name : $ds;
    is($name, 'Alpha', 'implicit default is the first stage');
};

subtest 'eager_stages' => sub {
    my $p     = My::Preload::Eager::TEST2_HARNESS_PRELOAD();
    my $eager = $p->eager_stages;
    ok(exists $eager->{EagerStage},  'eager stage in eager_stages');
    ok(!exists $eager->{QuietStage}, 'non-eager stage absent');
};

subtest 'duplicate stage name croaks' => sub {
    my $ok  = eval { My::Preload::DupFirst::stage('Dup', sub {}); 1 };
    my $err = $@;
    ok(!$ok, 'second registration of Dup dies');
    like($err, qr/already defined/, 'error says "already defined"');
};

subtest 'stage code error propagates' => sub {
    my $ok  = eval { My::Preload::BadCode::stage('Baddie', sub { die "intentional error\n" }); 1 };
    my $err = $@;
    ok(!$ok, 'stage with dying code propagates error');
    like($err, qr/intentional error/, 'correct error text');
};

subtest 'set_default_stage croaks when called a second time' => sub {
    my $p = Test2::Harness2::Preload->new;
    $p->set_default_stage('First');
    my $ok  = eval { $p->set_default_stage('Second'); 1 };
    my $err = $@;
    ok(!$ok, 'second call to set_default_stage dies');
    like($err, qr/already set/, 'error says "already set"');
};

subtest 'merge combines two preload trees' => sub {
    my $combined = Test2::Harness2::Preload->new;
    $combined->merge(My::Preload::MergeA::TEST2_HARNESS_PRELOAD());
    $combined->merge(My::Preload::MergeB::TEST2_HARNESS_PRELOAD());

    is(scalar @{$combined->stage_list}, 2, 'two stages after merge');
    ok(exists $combined->stage_lookup->{StageA}, 'StageA in merged tree');
    ok(exists $combined->stage_lookup->{StageB}, 'StageB in merged tree');
};

done_testing;
