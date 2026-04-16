use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/decode_json/;
use POSIX qw/_exit/;

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
        test_run                 => {files => [$test_file]},
        finish_after_initial_run => 1,
    );
    POSIX::_exit(0);
}

waitpid $pid, 0;
my $exit = $? >> 8;
is($exit, 0, 'service exited cleanly');

ok(-e "$dir/services/harness.jsonl", 'service log written');

# Find the run_id directory.
opendir my $dh, "$dir/runs" or die "Cannot open $dir/runs: $!";
my @runs = grep { !/^\./ } readdir $dh;
closedir $dh;
is(scalar @runs, 1, 'one run dir');

# Read the service log and confirm key events are present.
open my $slog, '<', "$dir/services/harness.jsonl" or die "Cannot open harness.jsonl: $!";
my @events = map { decode_json($_) } grep { /\S/ } <$slog>;
close $slog;

my %kinds = map { ($_->{facet_data}{harness}{kind} // '') => 1 } @events;
ok($kinds{service_started}, 'service_started event present');
ok($kinds{service_stopped}, 'service_stopped event present');

done_testing;
