use Test2::V0;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2::Run;

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
    is(scalar @{$run->pending}, 2, 'both pending');
    is(scalar @{$run->running}, 0, 'none running');
    is(scalar @{$run->done},    0, 'none done');
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

subtest 'mark_running / mark_done move job through states' => sub {
    my $run    = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    my $job_id = $run->jobs->[0]->job_id;

    $run->mark_running($job_id);
    is($run->pending, [],        'pending empty');
    is($run->running, [$job_id], 'running has job');

    $run->mark_done($job_id);
    is($run->running, [],        'running empty');
    is($run->done,    [$job_id], 'done has job');
    ok($run->is_complete, 'run is complete');
};

subtest 'requires files' => sub {
    my $ok = eval { Test2::Harness2::Run->from_files(); 1 };
    ok(!$ok, 'croaks without files');
};

subtest 'mark_running croaks on unknown job_id' => sub {
    my $run = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    my $ok  = eval { $run->mark_running('not-a-real-id'); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/not pending/);
};

subtest 'mark_done croaks when job is not running' => sub {
    my $run    = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    my $job_id = $run->jobs->[0]->job_id;
    my $ok     = eval { $run->mark_done($job_id); 1 };                     # never marked running
    my $err    = $@;
    ok(!$ok, 'croaked');
    like($err, qr/not running/);
};

subtest 'mark_* preserves FIFO order across multiple jobs' => sub {
    my $run  = Test2::Harness2::Run->from_files(files => [map _tf($_), 't/a.t', 't/b.t', 't/c.t']);
    my @jids = map { $_->job_id } @{$run->jobs};
    $run->mark_running($_) for @jids;
    is($run->running, \@jids, 'running preserves queue order');
    $run->mark_done($_) for reverse @jids;
    is($run->done, [reverse @jids], 'done reflects completion order, not queue order');
};

subtest 'empty run with no jobs is vacuously complete' => sub {
    my $run = Test2::Harness2::Run->new;
    ok($run->is_complete,        'empty run is complete');
    ok(defined $run->created_at, 'created_at populated');
    ok(defined $run->run_id,     'run_id populated');
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

subtest 'mark_skipped moves pending -> done without transitioning through running' => sub {
    my $run    = Test2::Harness2::Run->from_files(files => [_tf('t/a.t')]);
    my $job_id = $run->jobs->[0]->job_id;

    $run->mark_skipped($job_id);
    is($run->pending, [],        'pending empty');
    is($run->running, [],        'running untouched');
    is($run->done,    [$job_id], 'job landed in done');
    ok($run->is_complete, 'run complete');

    my $ok  = eval { $run->mark_skipped($job_id); 1 };
    my $err = $@;
    ok(!$ok, 'second skip croaks (already done)');
    like($err, qr/not pending/);
};

subtest 'TO_JSON returns a plain hash of slot values' => sub {
    my $run = Test2::Harness2::Run->from_files(
        run_id => 'r-1',
        files  => [_tf('t/a.t'), _tf('t/b.t')],
    );

    my $h = $run->TO_JSON;
    is(ref($h), 'HASH', 'returns a hashref');
    ok(!ref($h) || ref($h) eq 'HASH', 'outer return is unblessed');
    is($h->{run_id}, 'r-1', 'run_id present');
    ok(defined $h->{created_at}, 'created_at present');
    is(ref($h->{pending}), 'ARRAY', 'pending is arrayref');
    is(ref($h->{running}), 'ARRAY', 'running is arrayref');
    is(ref($h->{done}),    'ARRAY', 'done is arrayref');
    is(ref($h->{jobs}),    'ARRAY', 'jobs is arrayref');
    is(scalar @{$h->{jobs}}, 2,     'two jobs');
    ok($h->{jobs}[0]->can('TO_JSON'),
        'job entries implement TO_JSON (convert_blessed handles them at encode time)');
    is($h->{jobs}[0]->run_id, 'r-1', 'job inherits run_id');
};

done_testing;
