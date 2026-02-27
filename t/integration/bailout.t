use Test2::V0;
# HARNESS-DURATION-LONG

use App::Yath::Tester qw/yath/;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Test that BAIL_OUT causes yath to exit (not hang)
# Regression test for https://github.com/Test-More/Test2-Harness/issues/287
yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        ok($out->{exit}, "yath exits with non-zero when BAIL_OUT is encountered");
        like($out->{output}, qr/BAIL_OUT|bail|halt/i, "output mentions bail/halt");
    },
);

# Test that BAIL_OUT is ignored when --no-abort-on-bail is set
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '--no-abort-on-bail'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        # The test still fails (BAIL_OUT is a failure), but yath should
        # not abort the entire suite — just the bailing test fails
        ok($out->{exit}, "yath exits non-zero (test still fails)");
    },
);

# Test that when BAIL_OUT is disabled via env, everything passes
yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    env     => {BAILOUT_DO_PASS => 1},
    exit    => 0,
    test    => sub {
        my $out = shift;
        ok(!$out->{exit}, "yath exits cleanly when BAIL_OUT is not triggered");
    },
);

done_testing;
