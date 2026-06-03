use v5.38;

use File::Temp     qw/tempdir/;
use Time::HiRes    qw/sleep time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2;
use Test2::Harness2::Run;
use App::Yath2::TestFile;
use Test2::Harness2::Util::JSON qw/encode_json/;

# Drive a real harness service through one run of the given test file, then print
# (as JSON on STDOUT) the downstream monitor's snapshot of the run and its job.
# Used by t/AI/integration/monitor_runs_jobs.t, which captures and asserts it.

my $file = shift @ARGV or die "usage: monitor_snapshot.pl TEST_FILE\n";

my $h = Test2::Harness2->new(project => 'mon', workdir => tempdir(CLEANUP => 1));
$h->start;
my $mon = $h->subscribe;

my $run = Test2::Harness2::Run->new(run_uuid => gen_uuid(), run_ord => 1);
my $tf  = App::Yath2::TestFile->new(file => $file);
$run->add_job($tf->build_job(
    run_uuid => $run->run_uuid,
    run_ord  => 1,
    job_uuid => gen_uuid(),
    job_ord  => 1,
));

my $ruuid = $run->run_uuid;
my $juuid = $run->jobs->[0]->job_uuid;
my $specs = [map { $_->TO_JSON } @{$run->jobs}];

my $resp = $h->queue_run(run_uuid => $ruuid, jobs => $specs);
die "queue failed: $resp->{error}\n" unless $resp->{ok};

# Do NOT declare no_more_runs yet: keep the service alive until both the run has
# completed AND at least one system-load sample has propagated (the sampler is a
# freshly-forked process and a fast run can finish before its first report).
my $deadline = time + 60;
while (time < $deadline) {
    $h->poll_state;
    my $r = $mon->run($ruuid);
    last if $r && ($r->{state} // '') eq 'complete' && $mon->system_load;
    sleep 0.02;
}

$h->no_more_runs;
$h->shutdown;
$h->poll_state;    # flush any trailing frames buffered before the socket closed

print encode_json({
    run    => $mon->run($ruuid),
    job    => $mon->job($juuid),
    system => $mon->system_load,
});
