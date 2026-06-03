use Test2::V0;
use v5.38;

use File::Spec ();
use Test2::Harness2::Util::JSON qw/decode_json/;

# End-to-end: drive a real harness service through one run and assert the
# DOWNSTREAM (subscribed) monitor reconstructs the run and job state -- run
# lifecycle + counts + aggregate pass, and the job's spec and spawn config.
#
# Run the driver in a child process so the harness/collector get real STDOUT
# file descriptors (an in-process in-memory capture breaks the collector).

my @inc = map { File::Spec->rel2abs($_) } 'lib';

sub snapshot ($file) {
    my @cmd = ($^X, (map { "-I$_" } @inc), 't/AI/scripts/monitor_snapshot.pl', $file);
    my $out = `@{[ join ' ', @cmd ]}`;
    my ($json) = $out =~ /(\{.*\})/s;    # last-line JSON, ignore any stray output
    return $json ? decode_json($json) : undef;
}

subtest passing_run => sub {
    my $snap = snapshot('t/AI/scripts/collector_pass.pl');
    ok($snap, "got a snapshot") or return;

    my $run = $snap->{run};
    ok($run, "downstream tracked the run") or return;
    is($run->{state}, 'complete', "run reached complete");
    is($run->{job_count}, 1, "job_count is 1");
    is($run->{completed}, 1, "one job completed");
    is($run->{passed}, 1, "one job passed");
    is($run->{failed}, 0, "no jobs failed");
    is($run->{pass}, 1, "run aggregate pass");
    is($run->{job_uuids}, T(), "run carries a job uuid list");

    my $job = $snap->{job};
    ok($job, "downstream tracked the job") or return;
    is($job->{status}, 'finalized', "job finalized");
    like($job->{spec}{relative}, qr/collector_pass\.pl/, "job carries the scanned spec");
    is($job->{config}{is_test}, 1, "job carries spawn config (is_test)");
    like($job->{config}{exec}[-1], qr/collector_pass\.pl/, "spawn config exec names the test file");

    my $sys = $snap->{system};
    ok($sys, "downstream received a system load snapshot from the sampler") or return;
    ok(defined $sys->{ncpu}, "snapshot has a cpu count");
    ok(exists $sys->{cpu_pct}, "snapshot has a cpu_pct field");
    ok(defined $sys->{stamp}, "snapshot is stamped");
};

subtest failing_run => sub {
    my $snap = snapshot('t/AI/scripts/collector_fail.pl');
    ok($snap, "got a snapshot") or return;

    is($snap->{run}{state}, 'complete', "failing run still reaches complete");
    is($snap->{run}{passed}, 0, "no jobs passed");
    is($snap->{run}{failed}, 1, "one job failed");
    is($snap->{run}{pass}, 0, "run aggregate is not pass");
};

done_testing;
