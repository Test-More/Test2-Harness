use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec;
use Cwd qw/getcwd/;

use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# GH #283: yath --rerun-failed should use the default lastlog.jsonl location
# when no explicit log path is given.

my $workdir = tempdir(CLEANUP => 1);

# Step 1: Run tests with logging enabled to generate a lastlog.jsonl
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-L', '--log-dir' => $workdir],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{fail\.tx}, "first run saw the failing test");
        like($out->{output}, qr{pass\.tx}, "first run saw the passing test");
        like($out->{output}, qr{lastlog\.jsonl}, "first run created lastlog symlink");
    },
);

# Step 2: Verify the lastlog.jsonl symlink exists
ok(-e './lastlog.jsonl', 'lastlog.jsonl symlink exists after first run');

# Step 3: Run --rerun-failed without specifying a log path
yath(
    command => 'test',
    args    => ['--rerun-failed', '--ext=tx'],
    exit    => T(),
    test    => sub {
        my $out = shift;
        like($out->{output}, qr{fail\.tx}, "rerun-failed ran the failed test");
        unlike($out->{output}, qr{pass\.tx}, "rerun-failed did not run the passing test");
    },
);

# Cleanup the lastlog symlink we created
unlink('./lastlog.jsonl');

done_testing;
