use Test2::V0;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test: yath test succeeds with TEST2_HARNESS_NO_WRITE_TEST_INFO=1
# This exercises the same code path as an unwritable directory
yath(
    command => 'test',
    args    => ['--ext=tx', $dir],
    env     => { TEST2_HARNESS_NO_WRITE_TEST_INFO => 1 },
    exit    => 0,
    test    => sub {
        my $out = shift;
        ok(!$out->{exit}, "yath exits successfully with TEST2_HARNESS_NO_WRITE_TEST_INFO=1");
    },
);

# Test: yath test succeeds normally (write_test_info runs and cleans up)
yath(
    command => 'test',
    args    => ['--ext=tx', $dir],
    exit    => 0,
    test    => sub {
        my $out = shift;
        ok(!$out->{exit}, "yath exits successfully in writable dir");
    },
);

done_testing;
