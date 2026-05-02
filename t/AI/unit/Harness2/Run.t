use Test2::V0;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

sub _tf { Test2::Harness2::TestFile->new(file => $_[0]) }

subtest 'from_files builds jobs with inherited run_id' => sub {
    my $run = Test2::Harness2::Run->from_files(
        run_id => 'run-1',
        files  => [_tf('t/a.t'), _tf('t/b.t')],
    );
    is($run->run_id,                   'run-1', 'run_id set');
    is(scalar @{$run->jobs},           2,       'two jobs');
    is($run->jobs->[0]->run_id,        'run-1', 'job inherits run_id');
    is($run->jobs->[0]->test_file_rel, 't/a.t', 'job a relative path');
    is($run->jobs->[1]->test_file_rel, 't/b.t', 'job b relative path');
    isa_ok($run->jobs->[0]->test_file, ['Test2::Harness2::TestFile'], 'test_file is a TestFile');
};

subtest 'from_files accepts TestFile objects directly' => sub {
    my $tf  = Test2::Harness2::TestFile->new(file => 't/a.t', min_slots => 2);
    my $run = Test2::Harness2::Run->from_files(files => [$tf]);
    is($run->jobs->[0]->test_file,            $tf, 'pre-built TestFile passed through');
    is($run->jobs->[0]->test_file->min_slots, 2,   'attributes preserved');
};

subtest 'auto-generates run_id' => sub {
    my $run = Test2::Harness2::Run->from_files(files => [_tf('t/x.t')]);
    like($run->run_id, qr/^[0-9A-F-]{36}$/i, 'UUID run_id');
};

subtest 'requires files' => sub {
    my $ok = eval { Test2::Harness2::Run->from_files(); 1 };
    ok(!$ok, 'croaks without files');
};

subtest 'from_files rejects non-arrayref files' => sub {
    my $ok  = eval { Test2::Harness2::Run->from_files(files => 'not-an-array'); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/arrayref/);
};

subtest 'from_files rehydrates tagged hashrefs into TestFile objects' => sub {
    my $run = Test2::Harness2::Run->from_files(
        files => [
            {
                __test_file_class__ => 'Test2::Harness2::TestFile',
                file                => 't/a.t',
                min_slots           => 3,
            },
        ],
    );
    my $tf = $run->jobs->[0]->test_file;
    isa_ok($tf, ['Test2::Harness2::TestFile'], 'tagged hashref rehydrated');
    is($tf->min_slots, 3, 'attributes preserved across rehydrate');
};

subtest 'from_files rejects hashrefs missing __test_file_class__' => sub {
    my $ok  = eval { Test2::Harness2::Run->from_files(files => [{file => 't/a.t'}]); 1 };
    my $err = $@;
    ok(!$ok, 'croaked on untagged hash');
    like($err, qr/__test_file_class__/);
};

subtest 'from_files rejects path strings' => sub {
    my $ok  = eval { Test2::Harness2::Run->from_files(files => ['t/a.t']); 1 };
    my $err = $@;
    ok(!$ok, 'croaked on bare path string');
    like($err, qr/hashref/);
};

subtest 'from_files rejects non-TestFile/non-hash refs' => sub {
    my $ok  = eval { Test2::Harness2::Run->from_files(files => [\'scalar-ref']); 1 };
    my $err = $@;
    ok(!$ok, 'croaked on unexpected ref');
    like($err, qr/Role::TestFile|hashref/);
};

subtest 'add_job appends to the jobs list at queue-build time' => sub {
    my $run = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    is(scalar @{$run->jobs}, 1, 'one job to start');

    my $tf  = _tf('t/b.t');
    my $job = Test2::Harness2::Run::Job->new(test_file => $tf, run_id => $run->run_id);
    $run->add_job($job);
    is(scalar @{$run->jobs}, 2, 'two jobs after add_job');

    my $ok = eval { $run->add_job(undef); 1 };
    ok(!$ok, 'add_job croaks without a job');
    $ok = eval { $run->add_job({}); 1 };
    ok(!$ok, 'add_job croaks on a non-Run::Job ref');
};

subtest 'hash_seed slot (Phase 7.1) carries through from_files' => sub {
    my $no_seed = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    is($no_seed->hash_seed, undef, 'undef when not given');

    my $with_seed = Test2::Harness2::Run->from_files(
        files     => [_tf('t/a.t')],
        hash_seed => '20260428',
    );
    is($with_seed->hash_seed, '20260428', 'value preserved');
};

subtest 'TO_JSON returns a plain hash of spec slot values' => sub {
    my $run = Test2::Harness2::Run->from_files(
        run_id => 'r-1',
        files  => [_tf('t/a.t'), _tf('t/b.t')],
    );

    my $h = $run->TO_JSON;
    is(ref($h),      'HASH', 'returns a hashref');
    is($h->{run_id}, 'r-1',  'run_id present');
    ok(defined $h->{created_at}, 'created_at present');
    is(ref($h->{jobs}),      'ARRAY', 'jobs is arrayref');
    is(scalar @{$h->{jobs}}, 2,       'two jobs');
    ok(
        $h->{jobs}[0]->can('TO_JSON'),
        'job entries implement TO_JSON (convert_blessed handles them at encode time)'
    );
    is($h->{jobs}[0]->run_id, 'r-1', 'job inherits run_id');

    # Spec-only assertions: pending/running/done/results/aborted_reason
    # have moved to Run::State; the spec must not carry them.
    ok(!exists $h->{pending}, 'pending NOT on spec (lives on Run::State)');
    ok(!exists $h->{running}, 'running NOT on spec');
    ok(!exists $h->{done},    'done NOT on spec');
    ok(!exists $h->{results}, 'results NOT on spec');
};

subtest 'rehydrate round-trips through TO_JSON' => sub {
    my $run = Test2::Harness2::Run->from_files(
        run_id => 'r-rt',
        files  => [_tf('t/a.t')],
    );

    my $h = $run->TO_JSON;

    # Job entries are blessed in TO_JSON (TO_JSON returns a flat
    # hash; blessed Run::Job remain blessed inside). For round-trip
    # via decode_json we'd see them as plain hashes; simulate that
    # by stripping blessing.
    my @plain_jobs = map { +{%$_} } @{$h->{jobs}};
    my $h_plain    = {%$h, jobs => \@plain_jobs};

    my $r2 = Test2::Harness2::Run->rehydrate($h_plain);
    is($r2->run_id, 'r-rt', 'run_id round-tripped');
    isa_ok($r2->jobs->[0], ['Test2::Harness2::Run::Job'], 'job re-blessed');
    is($r2->jobs->[0]->run_id, 'r-rt', 'job carries run_id');
};

subtest 'requested_harness_uuid is a Spec slot for queue-time pinning' => sub {
    my $run = Test2::Harness2::Run->from_files(
        files                  => [_tf('t/a.t')],
        requested_harness_uuid => 'pinned-harness',
    );
    is($run->requested_harness_uuid, 'pinned-harness', 'requested_harness_uuid stored on the spec');

    my $h = $run->TO_JSON;
    is($h->{requested_harness_uuid}, 'pinned-harness', 'requested_harness_uuid in TO_JSON');
};

done_testing;
