use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/decode_json/;
use POSIX qw/_exit/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;

use Test2::Harness2;

my $dir = tempdir(CLEANUP => 1);

# Write a tiny test file to run.
my $test_file = "$dir/ok.t";
open my $fh, '>', $test_file or die $!;
print $fh <<'EOF';
use Test2::V0;
ok(1, "trivial pass");
done_testing;
EOF
close $fh;

# Start the service. Fork because start() takes over the process.
my $pid = fork // die $!;
if (!$pid) {
    Test2::Harness2->start(
        workdir                  => $dir,
        loggers                  => classic_harness_loggers($dir),
        test_loggers             => classic_test_loggers(),
        test_run                 => {files => [Test2::Harness2::TestFile->new(file => $test_file)]},
        finish_after_initial_run => 1,
    );
    POSIX::_exit(0);
}

waitpid $pid, 0;
my $exit = $? >> 8;
is($exit, 0, 'service exited cleanly');

ok(-e "$dir/logs/services/harness/events.jsonl", 'service log written');

# The run's services/ scratch dir is still created at RunService
# construction (resources scoped to the run land under there), so a
# run_id directory is visible even with no service loggers.
opendir my $dh, "$dir/logs/runs" or die "Cannot open $dir/logs/runs: $!";
my @run_dirs = grep { !/^\./ && -d "$dir/logs/runs/$_" } readdir $dh;
closedir $dh;
is(scalar @run_dirs, 1, 'one run dir');

# No .json / .jsonl assertion here: this test does not pass any
# service_loggers, so the run service deliberately writes nothing.

# Read the service log and confirm key events are present.
open my $slog, '<', "$dir/logs/services/harness/events.jsonl" or die "Cannot open harness.jsonl: $!";
my @events = map { decode_json($_) } grep { /\S/ } <$slog>;
close $slog;

my %kinds = map { ($_->{facet_data}{harness}{kind} // '') => 1 } @events;
ok($kinds{service_started}, 'service_started event present');
ok($kinds{service_stopped}, 'service_stopped event present');

done_testing;
