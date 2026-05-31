use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2;
use Test2::Harness2::Util::Zstd ();

# End-to-end: start a harness service, queue a run with one passing test, and
# observe the job complete (pass) via the subscribed monitor.

my $dir = tempdir(CLEANUP => 1);
my $h = Test2::Harness2->new(project => 'svc-test', workdir => $dir);
$h->start;
ok($h->service_pid, "service started");

my $mon = $h->subscribe;

my $resp = $h->queue_run(files => ['t/AI/scripts/collector_pass.pl']);
is($resp->{ok}, 1, "run queued");
my $job_uuid = $resp->{job_uuids}[0];
ok($job_uuid, "got a job uuid");

$h->no_more_runs;

# Poll until the job's final state is known.
my $final;
my $deadline = time + 60;
until ($final || time > $deadline) {
    $h->poll_state;
    $final = $mon->final_state($job_uuid);
    sleep 0.02;
}

ok($final, "saw the job's final state");
is($final->{pass}, 1, "the passing test passed");

$h->shutdown;
ok(!kill(0, $h->service_pid), "service process reaped");

# The service ran under a collector, so its output was captured to the service
# events file.
my $sf = $h->service_events_file;
ok(-e $sf, "service events file was written ($sf)");

my $reader = Test2::Harness2::Util::Zstd::open_zstd_reader($sf);
my $captured = '';
while (defined(my $line = $reader->readline)) { $captured .= $line }
like($captured, qr/harness service .* started/, "service startup output captured in its events file");

done_testing;
