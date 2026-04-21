use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();

use Test2::Harness2;

# Unit-level tests for the three artifact-enumeration request handlers
# added for Stage 12's command-side artifact-reading layer (see
# IPC_AND_LOGGERS §13.1).

sub _build_harness {
    my $wd = tempdir(CLEANUP => 1);
    return Test2::Harness2->new(workdir => $wd, name => 'harness');
}

subtest 'empty harness returns empty buckets' => sub {
    my $h = _build_harness();

    my $g = $h->request_handler_list_global_artifacts;
    ok($g->{ok}, 'list_global_artifacts ok');
    is($g->{artifacts}, {}, 'empty global bucket');

    my $r = $h->request_handler_list_run_artifacts({run_id => 'rid-42'});
    ok($r->{ok}, 'list_run_artifacts ok for unknown run');
    is($r->{artifacts}, {}, 'empty run bucket for an unseen run_id');
    is($r->{run_id}, 'rid-42', 'response echoes run_id');

    my $bad = $h->request_handler_list_run_artifacts({});
    ok(!$bad->{ok}, 'list_run_artifacts rejects missing run_id');
    like($bad->{error}, qr/run_id/, 'error mentions run_id');
};

subtest 'global collector_artifacts routing' => sub {
    my $h = _build_harness();

    $h->_record_artifacts({
        collector_id => 'collector:harness',
        loggers      => {
            'Test2::Harness2::Collector::Logger::JSONL' => [
                {output_file => '/tmp/a/harness.jsonl'},
            ],
        },
    });

    my $g = $h->request_handler_list_global_artifacts;
    ok($g->{ok}, 'global list ok');
    is(
        $g->{artifacts},
        {
            'collector:harness' => {
                collector_id => 'collector:harness',
                loggers      => {
                    'Test2::Harness2::Collector::Logger::JSONL' => [
                        {output_file => '/tmp/a/harness.jsonl'},
                    ],
                },
            },
        },
        'one global artifact recorded',
    );

    # Additive announcements: a follow-up message adds another instance.
    $h->_record_artifacts({
        collector_id => 'collector:harness',
        loggers      => {
            'Test2::Harness2::Collector::Logger::JSONL' => [
                {output_file => '/tmp/b/harness.jsonl'},
            ],
        },
    });

    my $g2 = $h->request_handler_list_global_artifacts;
    is(
        scalar @{$g2->{artifacts}{'collector:harness'}{loggers}{'Test2::Harness2::Collector::Logger::JSONL'}},
        2,
        'additive announcement appends instances',
    );
};

subtest 'run_id routing bucket separation' => sub {
    my $h = _build_harness();

    $h->_record_artifacts({
        collector_id => 'collector:run-A:test-1',
        run_id       => 'run-A',
        job_id       => 'job-1',
        job_try      => 0,
        loggers      => {
            'Test2::Harness2::Collector::Logger::JSONL' => [
                {output_file => '/tmp/run-A/job-1/0.jsonl'},
            ],
        },
    });

    $h->_record_artifacts({
        collector_id => 'collector:run-B:test-9',
        run_id       => 'run-B',
        job_id       => 'job-9',
        loggers      => {
            'Test2::Harness2::Collector::Logger::JSONL' => [
                {output_file => '/tmp/run-B/job-9/0.jsonl'},
            ],
        },
    });

    # Neither run shows up in globals.
    my $g = $h->request_handler_list_global_artifacts;
    is($g->{artifacts}, {}, 'run-scoped artifacts do not leak into globals');

    my $a = $h->request_handler_list_run_artifacts({run_id => 'run-A'});
    ok($a->{ok}, 'run-A list ok');
    is($a->{run_id}, 'run-A', 'run_id echoed');
    is(
        [sort keys %{$a->{artifacts}}],
        ['collector:run-A:test-1'],
        'run-A has one collector',
    );
    is(
        $a->{artifacts}{'collector:run-A:test-1'}{job_id},
        'job-1',
        'job_id preserved on run-A entry',
    );

    my $b = $h->request_handler_list_run_artifacts({run_id => 'run-B'});
    is(
        [sort keys %{$b->{artifacts}}],
        ['collector:run-B:test-9'],
        'run-B has its own collector only',
    );
};

subtest 'defensive copy: response mutation does not leak' => sub {
    my $h = _build_harness();

    $h->_record_artifacts({
        collector_id => 'collector:harness',
        loggers      => {
            'LClass' => [{output_file => '/tmp/x'}],
        },
    });

    my $g  = $h->request_handler_list_global_artifacts;
    my $x1 = $g->{artifacts}{'collector:harness'}{loggers}{LClass}[0];
    $x1->{output_file} = '/tmp/MUTATED';

    my $g2 = $h->request_handler_list_global_artifacts;
    is(
        $g2->{artifacts}{'collector:harness'}{loggers}{LClass}[0]{output_file},
        '/tmp/x',
        'mutating the response does not affect stored state',
    );
};

subtest 'get_run_status aliases run_status' => sub {
    my $h = _build_harness();

    my $direct = $h->request_handler_run_status({run_id => 'missing'});
    my $alias  = $h->request_handler_get_run_status({run_id => 'missing'});
    is($alias, $direct, 'get_run_status returns the same shape as run_status');
};

subtest '_ingest_run_artifacts batch-merges snapshots' => sub {
    my $h = _build_harness();

    $h->_ingest_run_artifacts(
        'run-X',
        {
            'collector:run-X:test-1' => {
                loggers => {
                    'Logger::JSONL' => [{output_file => '/tmp/run-X/1/0.jsonl'}],
                },
                job_id => 'job-1',
            },
            'collector:run-X:test-2' => {
                loggers => {
                    'Logger::JSONL' => [{output_file => '/tmp/run-X/2/0.jsonl'}],
                },
                job_id => 'job-2',
            },
        },
    );

    my $r = $h->request_handler_list_run_artifacts({run_id => 'run-X'});
    is([sort keys %{$r->{artifacts}}], ['collector:run-X:test-1', 'collector:run-X:test-2'], 'both collectors ingested');
};

done_testing;
