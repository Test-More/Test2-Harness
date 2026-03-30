use Test2::Require::Module 'Test::Harness' => '3.49';
use Test2::V0 -target => 'TAP::Harness::Yath::Aggregator';

subtest 'constructor with all fields' => sub {
    my $agg = CLASS->new(
        files_total    => 5,
        files_failed   => 1,
        files_passed   => 4,
        asserts_total  => 100,
        asserts_passed => 97,
        asserts_failed => 3,
    );
    ok($agg, "constructed aggregator");
};

subtest 'assertion count accessors' => sub {
    my $agg = CLASS->new(
        asserts_total  => 50,
        asserts_passed => 48,
        asserts_failed => 2,
    );

    is($agg->total,  50, "total() returns asserts_total");
    is($agg->passed, 48, "passed() returns asserts_passed");
    is($agg->failed, 2,  "failed() returns asserts_failed");
};

subtest 'file count accessors' => sub {
    my $agg = CLASS->new(
        files_total  => 10,
        files_failed => 2,
    );

    is($agg->total_files,  10, "total_files()");
    is($agg->failed_files, 2,  "failed_files()");
};

subtest 'has_errors with file failures' => sub {
    my $agg = CLASS->new(files_failed => 1);
    ok($agg->has_errors, "has_errors when files_failed > 0");
};

subtest 'has_errors with assertion failures' => sub {
    my $agg = CLASS->new(asserts_failed => 3);
    ok($agg->has_errors, "has_errors when asserts_failed > 0");
};

subtest 'has_errors is false when all pass' => sub {
    my $agg = CLASS->new(
        files_failed   => 0,
        asserts_failed => 0,
    );
    ok(!$agg->has_errors, "no errors when all zero");
};

subtest 'default values are undef/0' => sub {
    my $agg = CLASS->new;
    ok(!$agg->has_errors, "has_errors false with no data");
    is($agg->total,       undef, "total undef by default");
    is($agg->total_files, undef, "total_files undef by default");
};

done_testing;
