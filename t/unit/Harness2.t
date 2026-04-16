use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2;

subtest 'constructs with valid workdir' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    is($h->workdir, $dir,      'workdir stored');
    is($h->name,    'harness', 'name defaults to "harness"');
    like($h->job_id, qr/^[0-9A-F-]{36}$/i, 'job_id auto-generated');
    ok(-d "$dir/services", 'services/ dir created');
};

subtest 'rejects existing services/ directory' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services");
    my $ok  = eval { Test2::Harness2->new(workdir => $dir); 1 };
    my $err = $@;
    ok(!$ok, 'constructor dies');
    like($err, qr/services/, 'error mentions services');
};

subtest 'rejects existing runs/ directory' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs");
    my $ok = eval { Test2::Harness2->new(workdir => $dir); 1 };
    ok(!$ok, 'constructor dies on pre-existing runs/');
};

subtest 'tolerates other files in workdir' => sub {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/some-other-file.txt" or die;
    close $fh;
    my $ok = eval { Test2::Harness2->new(workdir => $dir); 1 };
    ok($ok, 'unrelated files are fine') or diag $@;
};

subtest 'workdir is required' => sub {
    my $ok = eval { Test2::Harness2->new; 1 };
    ok(!$ok, 'workdir is required');
};

subtest 'consumes IPC::Manager::Role::Service' => sub {
    ok(Test2::Harness2->DOES('IPC::Manager::Role::Service'), 'role applied');
};

subtest 'status returns current state without running' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $status = $h->handle_status_request;

    is($status->{service}{name},    'harness');
    is($status->{service}{pid},     $$);
    is($status->{service}{workdir}, $dir);
    is($status->{service}{state},   'running');
    like($status->{service}{job_id}, qr/^[0-9A-F-]{36}$/i);
    is($status->{queue},   [],    'empty queue');
    is($status->{running}, undef, 'nothing running');
};

subtest 'queue_test_run enqueues and returns run_id' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->handle_queue_test_run_request({files => ['t/a.t', 't/b.t']});
    ok($res->{ok}, 'accepted');
    like($res->{run_id}, qr/^[0-9A-F-]{36}$/i, 'returns a run_id');

    my $status = $h->handle_status_request;
    is(scalar @{$status->{queue}},             1,              'one run queued');
    is($status->{queue}[0]{run_id},            $res->{run_id}, 'matches returned id');
    is(scalar @{$status->{queue}[0]{pending}}, 2,              'two pending jobs');
};

subtest 'queue_test_run uses provided run_id when given' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my $res = $h->handle_queue_test_run_request({files => ['t/x.t'], run_id => 'my-id'});
    is($res->{run_id}, 'my-id');
};

subtest 'queue_test_run rejects when state is not running' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->{state} = 'finishing';
    my $res = $h->handle_queue_test_run_request({files => ['t/x.t']});
    ok(!$res->{ok}, 'rejected');
    like($res->{error}, qr/not accepting/);
};

subtest 'finish transitions running -> finishing and rejects further queueing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->handle_finish_request;
    ok($res->{ok}, 'finish accepted');
    is($h->{state}, 'finishing', 'state transitioned');

    my $q = $h->handle_queue_test_run_request({files => ['t/x.t']});
    ok(!$q->{ok}, 'subsequent queue rejected');

    my $again = $h->handle_finish_request;
    ok(!$again->{ok}, 'second finish returns ok=0');
};

subtest 'Terminate is idempotent and always accepted' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $r1 = $h->handle_terminate_request;
    ok($r1->{ok}, 'first accepted');
    is($h->{state}, 'terminating');

    my $r2 = $h->handle_terminate_request;
    ok($r2->{ok}, 'second still accepted');
};

subtest 'Detach removes a pid from watch_pids' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h = Test2::Harness2->new(workdir => $dir, parent_pids => [1001, 1002]);

    is($h->watch_pids, [1001, 1002]);

    my $res = $h->handle_detach_request({pid => 1001});
    ok($res->{ok});
    is($h->watch_pids, [1002], 'pid removed');

    # Idempotent: detaching an already-absent pid is also ok=1
    my $r2 = $h->handle_detach_request({pid => 1001});
    ok($r2->{ok});
    is($h->watch_pids, [1002]);
};

done_testing;
