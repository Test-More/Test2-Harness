# HARNESS2: conflicts yath
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Build a passing-only and a failing run via the test command, then
# replay each archive and verify pass/fail propagates through the
# replay command's exit code.

my $tmp = tempdir(CLEANUP => 1);
my $passdir = "$tmp/pass";
my $faildir = "$tmp/fail";
make_path($passdir, $faildir);

open(my $pf, '>', "$passdir/x.tx") or die $!;
print $pf "use Test2::V0;\nok(1, 'good');\ndone_testing;\n";
close $pf;

open(my $ff, '>', "$faildir/x.tx") or die $!;
print $ff "use Test2::V0;\nok(0, 'bad');\ndone_testing;\n";
close $ff;

my $pass_archive = "$tmp/pass.yath";
my $fail_archive = "$tmp/fail.yath";

yath(
    command => 'test',
    args    => [$passdir, '--ext=tx', "--log-file=$pass_archive"],
    exit    => 0,
);

yath(
    command => 'test',
    args    => [$faildir, '--ext=tx', "--log-file=$fail_archive"],
    exit    => T(),
);

ok(-f $pass_archive, 'pass archive created');
ok(-f $fail_archive, 'fail archive created');

yath(
    command => 'replay',
    args    => [$pass_archive],
    exit    => 0,
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/PASS:\s*job\b/, 'replay rendered the passing job');
    },
);

yath(
    command => 'replay',
    args    => [$fail_archive],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr/FAIL:\s*job\b/, 'replay rendered the failing job');
    },
);

# Missing path is rejected.
{
    my $missing = "$tmp/nope.yath";
    yath(
        command => 'replay',
        args    => [$missing],
        exit    => T(),
        test    => sub {
            my $out = shift;
            like($out->{output}, qr/does not exist/, 'replay errors on missing log');
        },
    );
}

done_testing;
