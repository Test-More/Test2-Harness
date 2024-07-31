use Test2::V0;
# HARNESS-DURATION-LONG

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

use Test2::Util qw/CAN_REALLY_FORK/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

skip_all "Cannot fork, skipping preload test"
    unless CAN_REALLY_FORK;

skip_all "This test requires forking" if $ENV{T2_NO_FORK};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-v', '-A', '-PTestSimplePreload', '-PTestPreload', '-p+TestPlugin'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        my $filtered = join "\n" => grep { m/(PASSED|FAILED|RETRY).*\.tx/ } split /\n/, $out->{output};

        like($filtered, qr{PASSED.*no_preload\.tx},   'Ran file "no_preload.tx"');
        like($filtered, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
        like($filtered, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
        like($filtered, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
        like($filtered, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
        like($filtered, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
        like($filtered, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
        like($filtered, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
        like($filtered, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
        like($filtered, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PTestSimplePreload', '-PTestPreload', '-PBroken', '-p+TestPlugin'],
    exit    => T(),
    env     => {TABLE_TERM_SIZE => 200},
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{This is broken}, "Reported the error");

        my $found_point = 0;
        my $failed = join "\n" => grep { $found_point ||= m/The following jobs failed:/ } split /\n/, $out->{output};
        like($failed, qr{\Q$_\E}, "$_ failed") for qw/no_preload.tx aaa.tx bbb.tx ccc.tx simple_test.tx preload_test.tx fast.tx slow.tx retry.tx retry.tx/;
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PTestBadPreload', '-p+TestPlugin' ],
    exit    => T(),
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{Can't locate Test2/Harness/Preload/Does/Not/Exist\.pm}, "Reported the error");
    },
);

unless ($ENV{AUTOMATED_TESTING}) {
    yath(
        command => 'start',
        args    => ['-PTestSimplePreload', '-PTestPreload', '-p+TestPlugin'],
        exit    => 0,
        test    => sub {
            yath(
                command => 'run',
                args    => [$dir, '--ext=tx', '-A', '-p+TestPlugin'],
                exit    => 0,
                test    => sub {
                    my $out = shift;

                    my $filtered = join "\n" => grep { m/(PASSED|FAILED|RETRY).*\.tx/ } split /\n/, $out->{output};

                    like($filtered, qr{PASSED.*no_preload\.tx},   'Ran file "no_preload.tx"');
                    like($filtered, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
                    like($filtered, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
                    like($filtered, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
                    like($filtered, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
                    like($filtered, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
                    like($filtered, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
                    like($filtered, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
                    like($filtered, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
                    like($filtered, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');
                },
            );

            yath(command => 'stop', exit => 0);
        },
    );

    # Persistent mode ignored broken preloads as they may be under active development
    yath(
        command => 'start',
        args    => ['-PTestSimplePreload', '-PTestPreload', '-PBroken', '-p+TestPlugin'],
        exit    => 0,
        test    => sub {
            yath(
                command => 'run',
                args    => [$dir, '--ext=tx', '-A', '-p+TestPlugin'],
                exit    => 0,
                test    => sub {
                    my $out = shift;

                    my $filtered = join "\n" => grep { m/(?:broken|(?:PASSED|FAILED|RETRY).*\.tx)/ } split /\n/, $out->{output};

                    like($filtered, qr{This is broken},           "Reported the error");
                    like($filtered, qr{PASSED.*no_preload\.tx},   'Ran file "no_preload.tx"');
                    like($filtered, qr{PASSED.*aaa\.tx},          'Ran file "aaa.tx"');
                    like($filtered, qr{PASSED.*bbb\.tx},          'Ran file "bbb.tx"');
                    like($filtered, qr{PASSED.*ccc\.tx},          'Ran file "ccc.tx"');
                    like($filtered, qr{PASSED.*simple_test\.tx},  'Ran file "simple_test.tx"');
                    like($filtered, qr{PASSED.*preload_test\.tx}, 'Ran file "preload_test.tx"');
                    like($filtered, qr{PASSED.*fast\.tx},         'Ran file "fast.tx"');
                    like($filtered, qr{PASSED.*slow\.tx},         'Ran file "slow.tx"');
                    like($filtered, qr{TO RETRY.*retry\.tx},      'Ran file "retry.tx" with a failure');
                    like($filtered, qr{PASSED.*retry\.tx},        'Ran file "retry.tx" again with a pass');
                },
            );

            yath(command => 'stop', exit => 0);
        },
    );
}

done_testing;
