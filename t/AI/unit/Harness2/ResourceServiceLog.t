use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::ResourceService qw//;

use Test2::Harness2;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# Resource that returns a single service entry. The generated service
# class records construction args on the instance so tests can inspect
# name / log_path propagation.
{

    package Test::OneService::Res;
    use Object::HashBase qw{<service_class <svc_name};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub mark_broken           { }
    sub mark_permanent_broken { }
    sub mark_paused           { }
    sub mark_resumed          { }

    sub services {
        my $self  = shift;
        my $class = $self->{+SERVICE_CLASS} or return ();
        my $name  = $self->{+SVC_NAME} // 'foo';
        return ([$class, name => $name]);
    }
}

# Resource that declares two distinct services, keyed by different
# names.
{

    package Test::TwoServices::Res;
    use Object::HashBase qw{<classes};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub mark_broken           { }
    sub mark_permanent_broken { }
    sub mark_paused           { }
    sub mark_resumed          { }

    # CLASSES is [[$class1, $name1], [$class2, $name2]]
    sub services {
        my $self = shift;
        return map { [$_->[0], name => $_->[1]] } @{$self->{+CLASSES} // []};
    }
}

sub _mk_res {
    my %opts = @_;
    my $cls  = Test2::Harness2::Test::ResourceService::make_service_class(%opts);
    return ($cls, Test::OneService::Res->new(service_class => $cls));
}

subtest 'global service lays down services/<name>/events.jsonl' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($cls, $res) = _mk_res(pid => 93_001);
    my $h = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->start_resource_services([$res], scope => 'global');

    my $expected = "$dir/logs/services/foo/events.jsonl";
    ok(-e $expected, "log file created at $expected");

    my $svc = $h->{resource_services}{93_001};
    ok($svc, 'tracking entry exists');
    is($svc->{name},          'foo',     'tracking entry records name');
    is($svc->{log_path},      $expected, 'tracking entry records log_path');
    is($svc->{service_class}, $cls,      'tracking entry records service_class');
};

subtest 'per-run service lays down runs/<run_id>/services/<name>/events.jsonl' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my ($cls, $res) = _mk_res(pid => 93_101);
    my $run = Test2::Harness2::Run->new(run_id => 'r-alpha', resources => [$res]);

    $h->start_resource_services([$res], scope => 'run', run => $run);

    my $expected = "$dir/logs/runs/r-alpha/services/foo/events.jsonl";
    ok(-e $expected, "log file created at $expected");

    my $svc = $h->{resource_services}{93_101};
    is($svc->{scope},    'run',     'tracking entry has run scope');
    is($svc->{log_path}, $expected, 'tracking entry points at per-run file');
    ref_is($svc->{run}, $run, 'tracking entry stores run ref');
};

subtest 'in-batch global name collision across two resources is rejected' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($c1, $res1) = _mk_res(pid => 93_010);
    my ($c2, $res2) = _mk_res(pid => 93_011);
    my $h = Test2::Harness2->new(workdir => $dir, resources => [$res1, $res2]);

    my $ok  = eval { $h->start_resource_services([$res1, $res2], scope => 'global'); 1 };
    my $err = $@;
    ok(!$ok, 'start croaked');
    like($err, qr/collides with in-batch service/, 'explains the collision');
    is(scalar keys %{$h->{resource_services}}, 0, 'no services tracked after failure');
};

subtest 'per-run name collision within the same run is rejected' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my ($c1, $res1) = _mk_res(pid => 93_020);
    my ($c2, $res2) = _mk_res(pid => 93_021);
    my $run = Test2::Harness2::Run->new(run_id => 'r-dup', resources => [$res1, $res2]);

    my $ok = eval {
        $h->start_resource_services([$res1, $res2], scope => 'run', run => $run);
        1;
    };
    my $err = $@;
    ok(!$ok, 'per-run start croaked');
    like($err, qr/collides with in-batch service/, 'explains the collision');
};

subtest 'name is allowed to collide across scopes (global vs run)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($cg, $glob) = _mk_res(pid => 93_201);
    my ($cr, $runr) = _mk_res(pid => 93_202);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$glob]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-cross', resources => [$runr]);

    $h->start_resource_services([$glob], scope => 'global');
    my $ok = eval {
        $h->start_resource_services([$runr], scope => 'run', run => $run);
        1;
    };
    my $err = $@;
    ok($ok,                                            'run-scoped reuse of a global name is allowed') or diag $err;
    ok(-e "$dir/logs/services/foo/events.jsonl",              'global log at services/foo/events.jsonl');
    ok(-e "$dir/logs/runs/r-cross/services/foo/events.jsonl", 'run log at runs/r-cross/services/foo/events.jsonl');
};

subtest 'names are allowed to collide across different runs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my ($ca, $ra) = _mk_res(pid => 93_301);
    my ($cb, $rb) = _mk_res(pid => 93_302);
    my $runA = Test2::Harness2::Run->new(run_id => 'r-A', resources => [$ra]);
    my $runB = Test2::Harness2::Run->new(run_id => 'r-B', resources => [$rb]);

    $h->start_resource_services([$ra], scope => 'run', run => $runA);
    my $ok = eval {
        $h->start_resource_services([$rb], scope => 'run', run => $runB);
        1;
    };
    my $err = $@;
    ok($ok,                                        'separate runs may share service names') or diag $err;
    ok(-e "$dir/logs/runs/r-A/services/foo/events.jsonl", 'run A has its own events.jsonl');
    ok(-e "$dir/logs/runs/r-B/services/foo/events.jsonl", 'run B has its own events.jsonl');
};

subtest "harness's own NAME is reserved in global scope" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($cls, $res) = _mk_res(pid => 93_050);
    my $h = Test2::Harness2->new(workdir => $dir, name => 'foo', resources => [$res]);

    my $ok  = eval { $h->start_resource_services([$res], scope => 'global'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks');
    like($err, qr/reserved by the global service/, 'error mentions reservation');
};

subtest 'harness name is not reserved in per-run scope' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, name => 'foo');
    my ($cls, $res) = _mk_res(pid => 93_400);
    my $run = Test2::Harness2::Run->new(run_id => 'r-ns', resources => [$res]);

    my $ok = eval { $h->start_resource_services([$res], scope => 'run', run => $run); 1 };
    ok($ok,                                         'per-run usage of the harness-reserved name is permitted');
    ok(-e "$dir/logs/runs/r-ns/services/foo/events.jsonl", 'per-run log created regardless of global reservation');
};

subtest 'one resource with two services gets two distinct log files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $cA  = Test2::Harness2::Test::ResourceService::make_service_class(pid => 93_500);
    my $cB  = Test2::Harness2::Test::ResourceService::make_service_class(pid => 93_501);
    my $res = Test::TwoServices::Res->new(classes => [[$cA, 'alpha'], [$cB, 'beta']]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->start_resource_services([$res], scope => 'global');

    ok(-e "$dir/logs/services/alpha/events.jsonl", 'alpha log created');
    ok(-e "$dir/logs/services/beta/events.jsonl",  'beta log created');

    my %by_name = map { ($_->{name} => $_) } values %{$h->{resource_services}};
    ok(exists $by_name{alpha}, 'alpha service tracked');
    ok(exists $by_name{beta},  'beta service tracked');
    isnt($by_name{alpha}{log_path}, $by_name{beta}{log_path}, 'log paths differ');
};

subtest 'restart reuses the same name + log_path' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $cls = Test2::Harness2::Test::ResourceService::make_service_class(
        restartable => 1,
        pids        => [93_701, 93_702],
    );
    my $res = Test::OneService::Res->new(service_class => $cls);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);
    $h->start_resource_services([$res], scope => 'global');

    my $expected = "$dir/logs/services/foo/events.jsonl";
    is($h->{resource_services}{93_701}{log_path}, $expected, 'initial log_path set');

    # Simulate the original pid exiting; restart picks up pid 93_702.
    $h->run_on_pid(93_701, 0);

    ok(!exists $h->{resource_services}{93_701}, 'old pid dropped');
    ok(exists $h->{resource_services}{93_702},  'new pid tracked');
    is($h->{resource_services}{93_702}{name},     'foo',     'restart preserves name');
    is($h->{resource_services}{93_702}{log_path}, $expected, 'restart preserves log_path');
};

subtest 'track_resource_service requires a service_class' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res;
    my ($cls, $r) = _mk_res(pid => 9);
    $res = $r;

    my $ok = eval {
        $h->track_resource_service(pid => 9_999_801, resource => $res, name => 'foo');
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaks without service_class');
    like($err, qr/service_class/, 'error mentions service_class');
};

subtest 'track_resource_service rejects a duplicate name directly' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($c1, $res1) = _mk_res(pid => 1);
    my ($c2, $res2) = _mk_res(pid => 2);
    my $h = Test2::Harness2->new(workdir => $dir);

    $h->track_resource_service(
        pid           => 9_999_901,
        resource      => $res1,
        service_class => $c1,
        service_args  => [],
        name          => 'foo',
    );
    my $ok = eval {
        $h->track_resource_service(
            pid           => 9_999_902,
            resource      => $res2,
            service_class => $c2,
            service_args  => [],
            name          => 'foo',
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'direct duplicate across resources rejected');
    like($err, qr/already in use/, 'error mentions reuse');
};

done_testing;
