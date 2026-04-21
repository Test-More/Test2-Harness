use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::ResourceService qw//;

use Test2::Harness2::RunService;
use Test2::Harness2::Run;

# Inline resource that declares one service via the new services()
# API. Records the harness object the service was spawned against via
# an on_spawn hook so tests can assert that the run service (not the
# main harness) is what gets passed.
{

    package Test::RunSvc::Res;
    use Object::HashBase qw{<pids <last_host +service_class};
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

    sub _service_class {
        my $self = shift;
        return $self->{+SERVICE_CLASS} //= Test2::Harness2::Test::ResourceService::make_service_class(
            pids => $self->{+PIDS} // [],
        );
    }

    sub services {
        my $self = shift;
        return ([$self->_service_class, name => 'foo']);
    }
}

subtest 'constructs with required attributes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-1');

    my $svc = Test2::Harness2::RunService->new(
        workdir => $dir,
        run     => $run,
    );

    is($svc->log_name, 'run',     'default log_name');
    is($svc->name,     'run-r-1', 'default bus name includes run_id for uniqueness');
    is($svc->run_id,   'r-1',     'run_id derived from run');
    is($svc->workdir,  $dir,      'workdir stored');
    ok(-d "$dir/logs/runs/r-1/services", 'services dir created at construction');
    is(
        $svc->log_file,
        "$dir/logs/runs/r-1/services/run.jsonl",
        'log file path is runs/<id>/services/<log_name>.jsonl',
    );
    is($svc->loggers,      [], 'loggers default is empty arrayref');
    is($svc->test_loggers, [], 'test_loggers default is empty arrayref');
};

subtest 'requires workdir' => sub {
    my $ok  = eval { Test2::Harness2::RunService->new(run => Test2::Harness2::Run->new(run_id => 'r')); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/workdir/);
};

subtest 'requires a Run object' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ok  = eval { Test2::Harness2::RunService->new(workdir => $dir, run => 'not-a-run'); 1 };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/Test2::Harness2::Run/);
};

subtest 'consumes the IPC service + resource host roles' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $svc = Test2::Harness2::RunService->new(
        workdir => $dir,
        run     => Test2::Harness2::Run->new(run_id => 'r-role'),
    );
    require Role::Tiny;
    ok(
        Role::Tiny::does_role($svc, 'IPC::Manager::Role::Service'),
        'is an IPC::Manager service',
    );
    ok(
        Role::Tiny::does_role($svc, 'Test2::Harness2::Role::ResourceServiceHost'),
        'is a resource-service host',
    );
    is($svc->service_host_scope, 'run', 'scope is run');
    ok(ref($svc->service_host_run), 'host run is the Run object');
};

subtest 'resource-service startup lands under runs/<id>/services/' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::RunSvc::Res->new(pids => [910_001]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-start', resources => [$res]);
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    # Skip run_on_start (which tries setpgid + emits events) and go
    # directly to the resource host role -- same call it would make.
    $svc->start_resource_services($run->resources, scope => 'run', run => $run);

    my $expected = "$dir/logs/runs/r-start/services/foo.jsonl";
    ok(-e $expected, "resource log at $expected");
    is(scalar keys %{$svc->{resource_services}}, 1, 'one service tracked');

    my ($entry) = values %{$svc->{resource_services}};
    is($entry->{name},     'foo',     'tracked name');
    is($entry->{log_path}, $expected, 'tracked log_path');
};

subtest 'run service name is reserved in its own per-run scope' => sub {
    my $dir = tempdir(CLEANUP => 1);

    {

        package Test::RunSvc::Clash;
        use Object::HashBase qw{+service_class};
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

        sub _svc_class {
            my $self = shift;
            return $self->{+SERVICE_CLASS} //= Test2::Harness2::Test::ResourceService::make_service_class(pid => 1);
        }

        # Collides with the run service's own 'run' log name.
        sub services {
            my $self = shift;
            return ([$self->_svc_class, name => 'run']);
        }
    }

    my $res = Test::RunSvc::Clash->new;
    my $run = Test2::Harness2::Run->new(run_id => 'r-clash', resources => [$res]);
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my $ok  = eval { $svc->start_resource_services($run->resources, scope => 'run', run => $run); 1 };
    my $err = $@;
    ok(!$ok, 'collision detected');
    like($err, qr/reserved by the run service itself/, 'error message explains');
};

subtest 'per-run usage of a name matching the global harness is allowed' => sub {
    # Flip side of the reservation: the run service only reserves in
    # its own scope. A resource named 'harness' or anything else is
    # fine under a run service.
    my $dir = tempdir(CLEANUP => 1);

    {

        package Test::RunSvc::Harnessy;
        use Object::HashBase qw{<pids +service_class};
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

        sub _svc_class {
            my $self = shift;
            return $self->{+SERVICE_CLASS} //= Test2::Harness2::Test::ResourceService::make_service_class(
                pids => $self->{+PIDS} // [],
            );
        }

        sub services {
            my $self = shift;
            return ([$self->_svc_class, name => 'harness']);
        }
    }

    my $res = Test::RunSvc::Harnessy->new(pids => [910_501]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-harnessy', resources => [$res]);
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    my $ok = eval { $svc->start_resource_services($run->resources, scope => 'run', run => $run); 1 };
    ok($ok,                                                   'no reservation conflict');
    ok(-e "$dir/logs/runs/r-harnessy/services/harness.jsonl", 'per-run harness.jsonl created');
};

subtest 'terminate handler transitions to terminating' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->new(run_id => 'r-term');
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    # With no resource services alive, perform_hard_stop is a no-op
    # and the state transitions cleanly to terminating.
    my $rv = $svc->request_handler_terminate;
    is($rv,           {ok => 1},     'terminate accepted');
    is($svc->{state}, 'terminating', 'state moved to terminating');
    ok($svc->run_should_end, 'run_should_end true after terminate with no children');
};

subtest 'status handler returns a sensible snapshot' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::RunSvc::Res->new(pids => [910_601]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-status', resources => [$res]);
    my $svc = Test2::Harness2::RunService->new(workdir => $dir, run => $run);

    $svc->start_resource_services($run->resources, scope => 'run', run => $run);

    my $st = $svc->request_handler_status;
    is($st->{service}{run_id},             'r-status', 'run_id in status');
    is($st->{service}{state},              'running',  'state in status');
    is(scalar @{$st->{resource_services}}, 1,          'one resource service reported');
    is($st->{resource_services}[0]{name},  'foo',      'resource service named foo');
};

done_testing;
