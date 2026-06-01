use Test2::V0;
use v5.38;

use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# A Run is just an identity plus its jobs.

subtest requires => sub {
    like(dies { Test2::Harness2::Run->new(run_ord => 1) }, qr/'run_uuid' is a required attribute/, "run_uuid required");
    like(dies { Test2::Harness2::Run->new(run_uuid => 'R') }, qr/'run_ord' is a required attribute/, "run_ord required");
};

subtest jobs => sub {
    my $run = Test2::Harness2::Run->new(run_uuid => 'R', run_ord => 1);
    is($run->jobs, [], "jobs defaults to empty arrayref");
    is($run->job_uuids, [], "no job uuids yet");

    my $job = Test2::Harness2::Run::Job->new(
        run_uuid => 'R', run_ord => 1, job_uuid => 'J1', job_ord => 1, file => 'a.t',
    );
    my $ret = $run->add_job($job);
    ref_is($ret, $job, "add_job returns the job");
    is(scalar(@{$run->jobs}), 1, "job was added");
    is($run->job_uuids, ['J1'], "job_uuids lists the uuid");
};

done_testing;
