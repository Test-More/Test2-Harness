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

# Find the run_id directory and the QueueJSON snapshot.
opendir my $dh, "$dir/runs" or die "Cannot open $dir/runs: $!";
my @entries = sort grep { !/^\./ } readdir $dh;
closedir $dh;
my @run_dirs  = grep { -d "$dir/runs/$_" } @entries;
my @run_jsons = grep { /\.json$/ } @entries;
is(scalar @run_dirs,  1, 'one run dir');
is(scalar @run_jsons, 1, 'one QueueJSON run snapshot');

my ($run_id) = $run_dirs[0];
is($run_jsons[0], "$run_id.json", 'run snapshot filename matches run_id');

# The run snapshot should contain the full run structure.
open my $rjson, '<', "$dir/runs/$run_jsons[0]" or die "Cannot open run snapshot: $!";
my $run_data = decode_json(do { local $/; <$rjson> });
close $rjson;
is($run_data->{run_id}, $run_id,   'run snapshot run_id matches directory');
is(scalar @{$run_data->{jobs}}, 1, 'one job in run snapshot');
is($run_data->{jobs}[0]{test_file_abs}, $test_file, 'job references test_file_abs');

# The per-job snapshot should live at runs/RUN_ID/JOB_ID.json.
my $job_id = $run_data->{jobs}[0]{job_id};
my $job_snapshot_path = "$dir/runs/$run_id/$job_id.json";
ok(-f $job_snapshot_path, 'per-job snapshot file exists');
open my $jjson, '<', $job_snapshot_path or die "Cannot open job snapshot: $!";
my $job_data = decode_json(do { local $/; <$jjson> });
close $jjson;
is($job_data->{job_id},        $job_id,    'job snapshot job_id matches');
is($job_data->{run_id},        $run_id,    'job snapshot run_id matches');
is($job_data->{test_file_abs}, $test_file, 'job snapshot test_file_abs matches');

# Read the service log and confirm key events are present.
open my $slog, '<', "$dir/services/harness.jsonl" or die "Cannot open harness.jsonl: $!";
my @events = map { decode_json($_) } grep { /\S/ } <$slog>;
close $slog;

my %kinds = map { ($_->{facet_data}{harness}{kind} // '') => 1 } @events;
ok($kinds{service_started}, 'service_started event present');
ok($kinds{service_stopped}, 'service_stopped event present');
ok($kinds{run_queued},      'run_queued event present');
ok($kinds{run_ended},       'run_ended event present');
ok($kinds{test_start},      'test_start event present');
ok($kinds{test_complete},   'test_complete event present');

done_testing;
