use Test2::V0;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::JSON qw/decode_json/;
use File::Spec();
use File::Temp qw/tempdir/;

# Always somewhere of our own. The bundle defaults to the directory yath was
# run from, and the suite must not need the distribution directory to be
# writable -- at install time it may not be.
my $BUNDLE_DIR = tempdir(CLEANUP => 1);

sub bundles {
    return glob(File::Spec->catfile($BUNDLE_DIR, 'yath-stall-report-*.json'));
}

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# BlockingResource lets one test start, then blocks the scheduler inside
# available() for a bounded period before letting the rest through. With a
# short --stall-report the main process should notice and print a report while
# the scheduler is still stuck, and the run should still finish normally --
# reporting never ends a run.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+BlockingResource', '--stall-report=3:3', "--stall-report-dir=$BUNDLE_DIR"],
    # The fixture stops blocking as soon as its stack has been taken, so this
    # is a ceiling for a machine too slow to get there, not a wait. It stays
    # well under App::Yath::Tester's own timeout, which would kill the run.
    env     => {BLOCKING_RESOURCE_MAX => 30},
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr/YATH STALL REPORT BEGIN/, "printed a stall report");
        like($out->{output}, qr/no test has started in/,  "said what it observed");
        like($out->{output}, qr/may be benign/,           "said the report may be benign");

        # The whole signal-to-trace chain: four separate call sites have to
        # agree on the stall directory, and if any disagrees the report says
        # "No stack traces were produced" -- indistinguishable from the
        # legitimate case where a process could not run its handler.
        like($out->{output}, qr/BlockingResource::available/, "captured the stack of the stuck scheduler");

        my @bundles = bundles();
        ok(@bundles, "wrote a bundle that outlives the run") or return;

        my $size = -s $bundles[0];
        ok($size > 1024, "bundle has the detail the text report leaves out") or diag("size: $size");

        like($bundles[0], qr/yath-stall-report-[0-9A-F-]+-\d+\.json$/i, "named by run id and report number");

        # The bundle also goes into the aux log, which the collector forwards
        # to the yath UI. It has to be one physical line there, or the
        # collector makes an info facet per line instead of one for the whole
        # bundle. encode_json escapes embedded newlines, which is what keeps
        # that true however large the bundle gets.
        # The renderer prefixes the tag it derived from the aux log's name;
        # what matters is that the bundle is one line behind that prefix.
        my ($line) = map { m/^\(\s*STALL\s*\)\s+(\{.*)$/ ? $1 : () } split /\n/, $out->{output};
        ok($line, "the bundle reached the log as a single line") or return;

        my $data = eval { decode_json($line) };
        ok($data,                                   "and it parses") or diag($@);
        ok($data->{samples} && @{$data->{samples}}, "with the per-process samples in it");
    },
);

# A healthy run says nothing about stalls and is not truncated.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', '--stall-report=60:60', "--stall-report-dir=$BUNDLE_DIR"],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr/STALL REPORT/, "no report on a healthy run");
    },
);

# Disabled by default.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2', "-D$dir", '-R+BlockingResource', "--stall-report-dir=$BUNDLE_DIR"],
    exit    => 0,
    test    => sub {
        my $out = shift;
        unlike($out->{output}, qr/STALL REPORT/, "no report when the option is not given");
    },
);

done_testing;
