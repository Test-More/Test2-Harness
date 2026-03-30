use Test2::V0 -target => 'Test2::Harness::Runner';
use File::Temp qw/tempdir/;

my $workdir = tempdir(CLEANUP => 1);

sub make_runner {
    return $CLASS->new(
        workdir       => $workdir,
        test_settings => {class => 'Test2::Harness::TestSettings'},
        @_,
    );
}

subtest 'required attributes' => sub {
    like(
        dies { $CLASS->new(test_settings => {class => 'Test2::Harness::TestSettings'}) },
        qr/workdir.*required/i,
        'workdir is required',
    );
    like(
        dies { $CLASS->new(workdir => $workdir) },
        qr/test_settings.*required/i,
        'test_settings is required',
    );
};

subtest 'basic construction' => sub {
    my $runner = make_runner();
    ok($runner->isa($CLASS), 'creates instance');
    is($runner->workdir, $workdir, 'workdir accessor');
    ok($runner->test_settings->isa('Test2::Harness::TestSettings'), 'test_settings inflated');
};

subtest 'test_settings accepts hashref and inflates it' => sub {
    my $runner = make_runner(test_settings => {class => 'Test2::Harness::TestSettings', lib => 0});
    ok($runner->test_settings->isa('Test2::Harness::TestSettings'), 'test_settings is a TestSettings object');
};

subtest 'ready always returns 1 for base runner' => sub {
    my $runner = make_runner();
    is($runner->ready, 1, 'ready() returns 1');
};

subtest 'stages returns [NONE] for base runner' => sub {
    my $runner = make_runner();
    is($runner->stages, ['NONE'], 'stages() returns [NONE]');
};

subtest 'stage_sets returns [[NONE,NONE]] for base runner' => sub {
    my $runner = make_runner();
    is($runner->stage_sets, [['NONE', 'NONE']], 'stage_sets() returns [[NONE,NONE]]');
};

subtest 'job_stage returns NONE for base runner' => sub {
    my $runner = make_runner();
    is($runner->job_stage(undef, undef), 'NONE', 'job_stage always returns NONE');
};

subtest 'terminate — first reason wins' => sub {
    my $runner = make_runner();
    ok(!$runner->terminated, 'not terminated initially');
    my $result = $runner->terminate('first');
    is($result,              'first', 'returns reason');
    is($runner->terminated,  'first', 'terminated set to first reason');
    $runner->terminate('second');
    is($runner->terminated,  'first', 'second call does not overwrite first reason');
};

subtest 'kill calls terminate with kill reason' => sub {
    my $runner = make_runner();
    $runner->kill;
    ok($runner->terminated, 'kill sets terminated');
};

subtest 'is_daemon attribute' => sub {
    my $runner = make_runner(is_daemon => 1);
    is($runner->is_daemon, 1, 'is_daemon accessor');
};

done_testing;
