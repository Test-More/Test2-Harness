# HARNESS2: conflicts yath
use Test2::V0;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

use Test2::Util qw/CAN_REALLY_FORK/;

skip_all "Cannot fork, skipping preload test"
    unless CAN_REALLY_FORK;

skip_all "T2_NO_FORK is set" if $ENV{T2_NO_FORK};

# Port of reference/legacy/t/integration/preload.t, simplified for the
# non-staged preload subsystem. Original used file_stage routing and
# named stages (AAA/BBB/CCC/FAST/SLOW); those no longer exist. What
# survives is the user-visible contract:
#
#   * `-PMod` causes Mod to be loaded once in the preload service and
#     remain in %INC for tests routed through the default bucket.
#   * Multiple `-P` modules in one invocation all preload.
#   * `HARNESS2: preload @off` opts a test out of the preload.
#   * A preload that dies at compile time fails `yath test` with a
#     non-zero exit and surfaces the error message in the output.
#   * A preload that references a missing module fails the same way
#     and surfaces the `Can't locate` error.

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

local $ENV{TABLE_TERM_SIZE} = 500;

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAISimplePreload', '-PAIPreload'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        # The new Terminal renderer (QVF default) prints `PASS: job N
        # try N` per passing job without the test file name. Count the
        # PASS lines and verify the run finished cleanly with no FAIL.
        my $pass_count = () = $out->{output} =~ /^PASS:\s*job\b/mg;
        is($pass_count, 3, 'three passing PASS lines (no_preload, preload_test, multi_test)');
        unlike($out->{output}, qr/^FAIL:/m, 'no FAIL lines in passing preload run');
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAIBroken'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{This is broken}, "broken preload's die message surfaced to user");
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '-PAIBadDep'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like(
            $out->{output},
            qr{Can't locate AIBadDep/Does/Not/Exist\.pm},
            "missing-dep preload error surfaced to user",
        );
    },
);

# Persistent mode: legacy convention -- skip under AUTOMATED_TESTING
# because real daemonization + yath stop is fragile under CI.
unless ($ENV{AUTOMATED_TESTING}) {
    # yath run does not carry the Finder option group, so --ext does
    # not exist there; enumerate the .tx files explicitly.
    my @tx_files = glob "$dir/*.tx";

    yath(
        command => 'start',
        args    => ['-PAISimplePreload', '-PAIPreload'],
        exit    => 0,
        test    => sub {
            yath(
                command => 'run',
                args    => [@tx_files],
                exit    => 0,
                test    => sub {
                    my $out = shift;
                    # See above: the new Terminal renderer prints
                    # `PASS: job N try N` per job without the filename.
                    my $pass_count = () = $out->{output} =~ /^PASS:\s*job\b/mg;
                    is($pass_count, 3, 'three passing PASS lines under daemon');
                    unlike($out->{output}, qr/^FAIL:/m, 'no FAIL lines under daemon run');
                },
            );

            yath(command => 'stop', exit => 0);
        },
    );
}

done_testing;
