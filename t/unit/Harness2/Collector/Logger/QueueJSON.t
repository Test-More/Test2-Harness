use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/decode_json/;

use Test2::Harness2::Collector::Logger::QueueJSON;
use Test2::Harness2::Event;

subtest 'applicable is restricted to service-kind contexts' => sub {
    ok(Test2::Harness2::Collector::Logger::QueueJSON->applicable({kind => 'service'}),
        'applicable in service context');
    ok(!Test2::Harness2::Collector::Logger::QueueJSON->applicable({kind => 'test'}),
        'not applicable in test context');
    ok(Test2::Harness2::Collector::Logger::QueueJSON->applicable({}),
        'applicable when kind is unset (backward-compat default)');
};

subtest 'workdir is required' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Logger::QueueJSON->new; 1 };
    my $err = $@;
    ok(!$ok, 'croaks without workdir');
    like($err, qr/workdir/, 'error mentions workdir');
};

subtest 'run_queued event produces runs/RUN_ID.json' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $logger = Test2::Harness2::Collector::Logger::QueueJSON->new(workdir => $dir);

    my $run = {
        run_id     => 'RUN-X',
        created_at => 1234.5,
        jobs       => [{
            job_id        => 'JOB-X',
            job_try       => 0,
            run_id        => 'RUN-X',
            test_file     => 't/foo.t',
            test_file_abs => '/tmp/t/foo.t',
        }],
        pending => ['JOB-X'],
        running => [],
        done    => [],
    };

    my $event = Test2::Harness2::Event->new(
        event_id   => '0',
        stamp      => 1,
        facet_data => {harness => {kind => 'run_queued', run => $run}},
    );

    $logger->log_event($event);

    my $path = "$dir/runs/RUN-X.json";
    ok(-f $path, 'snapshot file exists');

    open my $fh, '<', $path or die $!;
    my $data = decode_json(do { local $/; <$fh> });
    close $fh;

    is($data, $run, 'snapshot carries full run data');
};

subtest 'test_start event produces runs/RUN_ID/JOB_ID.json' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $logger = Test2::Harness2::Collector::Logger::QueueJSON->new(workdir => $dir);

    my $job = {
        run_id        => 'RUN-Y',
        job_id        => 'JOB-Y',
        job_try       => 0,
        test_file     => 't/bar.t',
        test_file_abs => '/tmp/t/bar.t',
    };

    my $event = Test2::Harness2::Event->new(
        event_id   => '2',
        stamp      => 1,
        facet_data => {harness => {
            kind   => 'test_start',
            run_id => 'RUN-Y',
            job_id => 'JOB-Y',
            job    => $job,
        }},
    );

    $logger->log_event($event);

    my $path = "$dir/runs/RUN-Y/JOB-Y.json";
    ok(-f $path, 'job snapshot file exists');

    open my $fh, '<', $path or die $!;
    my $data = decode_json(do { local $/; <$fh> });
    close $fh;

    is($data, $job, 'job snapshot carries full job data');
};

subtest 'ignores unrelated events' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $logger = Test2::Harness2::Collector::Logger::QueueJSON->new(workdir => $dir);

    my $event = Test2::Harness2::Event->new(
        event_id   => '1',
        stamp      => 1,
        facet_data => {harness => {kind => 'run_ended', run_id => 'R1'}},
    );

    $logger->log_event($event);

    opendir my $dh, "$dir" or die $!;
    my @entries = grep { !/^\./ } readdir $dh;
    closedir $dh;
    is(\@entries, [], 'no files created');
};

done_testing;
