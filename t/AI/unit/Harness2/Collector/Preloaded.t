use Test2::V0;

use Test2::Util qw/IS_WIN32/;
plan skip_all => 'Collector::Preloaded requires Unix (fork + goto::file)' if IS_WIN32;

use Test2::Harness2::Collector::Preloaded;

subtest 'inherits from Collector::Test' => sub {
    ok(
        Test2::Harness2::Collector::Preloaded->isa('Test2::Harness2::Collector::Test'),
        'is a Collector::Test',
    );
};

subtest 'init croaks without test_file' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Preloaded->new; 1 };
    my $err = $@;
    ok(!$ok, 'dies without test_file');
    like($err, qr/test_file/, 'error mentions test_file');
};

done_testing;
