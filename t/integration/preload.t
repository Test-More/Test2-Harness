use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "Cannot fork, skipping preload test"
    unless CAN_REALLY_FORK;

skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

subtest test => sub {
    my $out = yath(
        command => 'test',
        args    => [$dir, '--ext=tx', '-A', '-PTestSimplePreload', '-PTestPreload'],
    );

    ok(!$out->{exit}, "Exited success");
    like($out->{output}, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
    like($out->{output}, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
    like($out->{output}, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
    like($out->{output}, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
    like($out->{output}, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
    like($out->{output}, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
    like($out->{output}, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
    like($out->{output}, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
    like($out->{output}, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');
};

subtest test_broken => sub {
    my $out = yath(
        command => 'test',
        args    => [$dir, '--ext=tx', '-A', '-PTestSimplePreload', '-PTestPreload', '-PBroken'],
    );

    ok($out->{exit}, "Exited bady with broken preload");
    like($out->{output}, qr{This is broken},      "Reported the error");
    like($out->{output}, qr{No tests were seen!}, "No tests were run");
};

subtest persist => sub {
    my $out = yath(command => 'start', args => ['-PTestSimplePreload', '-PTestPreload']);
    ok(!$out->{exit}, "'start' command worked");

    $out = yath(command => 'run', args => [$dir, '--ext=tx', '-A']);
    ok(!$out->{exit}, "Exited success");
    like($out->{output}, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
    like($out->{output}, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
    like($out->{output}, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
    like($out->{output}, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
    like($out->{output}, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
    like($out->{output}, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
    like($out->{output}, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
    like($out->{output}, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
    like($out->{output}, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');

    yath(command => 'stop');
};

# Persistent mode ignored broken preloads as they may be under active development
subtest persist_broken => sub {
    my $out = yath(command => 'start', args => ['-PTestSimplePreload', '-PTestPreload', '-PBroken']);
    ok(!$out->{exit}, "'start' command worked");

    $out = yath(command => 'run', args => [$dir, '--ext=tx', '-A']);
    ok(!$out->{exit}, "Exited success");
    like($out->{output}, qr{This is broken},           "Reported the error");
    like($out->{output}, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
    like($out->{output}, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
    like($out->{output}, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
    like($out->{output}, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
    like($out->{output}, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
    like($out->{output}, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
    like($out->{output}, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
    like($out->{output}, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
    like($out->{output}, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');

    yath(command => 'stop');
};

done_testing;
