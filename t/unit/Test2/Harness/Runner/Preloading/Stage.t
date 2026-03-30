use Test2::V0 -target => 'Test2::Harness::Runner::Preloading::Stage';
use Test2::Util qw/IS_WIN32/;

skip_all 'Preloading stage is not supported on Windows' if IS_WIN32;

# Stage does not inflate test_settings - pass a pre-built object
my $ts = do {
    require Test2::Harness::TestSettings;
    Test2::Harness::TestSettings->new;
};

sub make_stage {
    my %args = @_;
    return $CLASS->new(
        name          => 'TEST',
        test_settings => $ts,
        root_pid      => $$,
        %args,
    );
}

subtest 'basic construction' => sub {
    my $stage = make_stage();
    ok($stage->isa($CLASS), 'creates instance');
};

subtest 'name attribute' => sub {
    my $stage = make_stage(name => 'MY_STAGE');
    is($stage->name, 'MY_STAGE', 'name accessor');
};

subtest 'test_settings stored as-is' => sub {
    my $stage = make_stage();
    ok($stage->test_settings->isa('Test2::Harness::TestSettings'), 'test_settings is a TestSettings object');
};

subtest 'root_pid attribute' => sub {
    my $stage = make_stage(root_pid => $$);
    is($stage->root_pid, $$, 'root_pid accessor');
};

subtest 'is_daemon attribute defaults' => sub {
    my $stage = make_stage();
    ok(!$stage->is_daemon, 'is_daemon defaults to false');
};

subtest 'is_daemon can be set' => sub {
    my $stage = make_stage(is_daemon => 1);
    is($stage->is_daemon, 1, 'is_daemon set to 1');
};

subtest 'terminate sets terminated reason' => sub {
    # Stage::terminate simply overwrites (no first-reason-wins semantics)
    my $stage = make_stage();
    ok(!$stage->terminated, 'not terminated initially');
    $stage->terminate('reason-one');
    is($stage->terminated, 'reason-one', 'terminated set after first call');
    $stage->terminate('reason-two');
    is($stage->terminated, 'reason-two', 'terminate overwrites with new reason');
};

subtest 'bad attribute' => sub {
    my $stage = make_stage(bad => 1);
    is($stage->bad, 1, 'bad accessor');
};

done_testing;
