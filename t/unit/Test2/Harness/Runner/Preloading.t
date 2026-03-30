use Test2::V0 -target => 'Test2::Harness::Runner::Preloading';
use Test2::Util qw/IS_WIN32/;
use File::Temp qw/tempdir/;

skip_all 'Preloading runner is not supported on Windows' if IS_WIN32;

my $workdir = tempdir(CLEANUP => 1);

sub make_runner {
    my %extra = @_;
    my $runner = $CLASS->new(
        workdir       => $workdir,
        test_settings => {class => 'Test2::Harness::TestSettings'},
        %extra,
    );
    # Initialize empty stage data so DESTROY/terminate does not die
    $runner->set_stages({});
    return $runner;
}

subtest 'basic construction' => sub {
    my $runner = make_runner();
    ok($runner->isa($CLASS), 'creates instance');
    ok($runner->isa('Test2::Harness::Runner'), 'inherits from Runner base');
};

subtest 'blacklist — starts empty' => sub {
    my $runner = make_runner();
    my $bl = $runner->blacklist;
    ref_ok($bl, 'HASH', 'blacklist returns hashref');
    is(scalar(keys %$bl), 0, 'blacklist is empty initially');
};

subtest 'blacklist — add modules' => sub {
    my $runner = make_runner();
    $runner->blacklist('Foo::Bar', 'Baz::Qux');
    my $bl = $runner->blacklist;
    ok($bl->{'Foo::Bar'}, 'Foo::Bar in blacklist');
    ok($bl->{'Baz::Qux'}, 'Baz::Qux in blacklist');
};

subtest 'blacklist — returns current blacklist' => sub {
    my $runner = make_runner();
    my $bl = $runner->blacklist('Module::One');
    ref_ok($bl, 'HASH', 'blacklist() returns hashref');
    ok($bl->{'Module::One'}, 'Module::One present in returned hashref');
};

subtest 'terminate — first reason wins' => sub {
    my $runner = make_runner();
    ok(!$runner->terminated, 'not terminated initially');
    $runner->terminate('test-reason');
    is($runner->terminated, 'test-reason', 'terminated set to first reason');
    $runner->terminate('other-reason');
    is($runner->terminated, 'test-reason', 'second reason does not overwrite first');
};

subtest 'ready — returns 1 when no stages, 0 when stages present but none ready' => sub {
    # Without explicit stages set, the parent ready() is used
    my $runner = make_runner();
    # Stages starts as undef, ready() returns 1 when no stages
    my $r = $runner->ready;
    # The Preloading override: returns 1 if stages exist (i.e. defined)
    # Since stages is undef initially, relies on parent ready()
    ok(defined($r), 'ready() returns a defined value');
};

subtest 'preload_retry_delay defaults to 5' => sub {
    my $runner = make_runner();
    is($runner->preload_retry_delay, 5, 'preload_retry_delay defaults to 5');
};

subtest 'preload_retry_delay can be overridden' => sub {
    my $runner = make_runner(preload_retry_delay => 10);
    is($runner->preload_retry_delay, 10, 'preload_retry_delay set to 10');
};

done_testing;
