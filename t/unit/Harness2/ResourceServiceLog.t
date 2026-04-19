use Test2::V0;
use File::Temp qw/tempdir/;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2;
use Test2::Harness2::Run;
use Test2::Harness2::Run::Job;

# Resource with a single service_foo method. Records the named arguments
# the method receives so tests can assert name / log_path propagation.
{

    package Test::OneService;
    use Object::HashBase qw{<pids <last_args};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub init { $_[0]->{+PIDS} //= [] }

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub service_foo {
        my ($self, %p) = @_;
        $self->{+LAST_ARGS} = {%p};
        my $pid = shift @{$self->{+PIDS}} // 90_000;
        $p{harness}->track_resource_service(
            pid      => $pid,
            resource => $self,
            method   => 'service_foo',
            name     => $p{name},
            log_path => $p{log_path},
            scope    => $p{scope},
            (defined $p{run} ? (run => $p{run}) : ()),
        );
        return 0;    # not restartable
    }
}

# Second resource class that also declares service_foo -- used to exercise
# in-batch and same-scope cross-resource collision.
{

    package Test::OtherService;
    use Object::HashBase qw{<pids};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub init { $_[0]->{+PIDS} //= [] }

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub service_foo {
        my ($self, %p) = @_;
        my $pid = shift @{$self->{+PIDS}} // 91_000;
        $p{harness}->track_resource_service(
            pid      => $pid,
            resource => $self,
            method   => 'service_foo',
            name     => $p{name},
            log_path => $p{log_path},
            scope    => $p{scope},
            (defined $p{run} ? (run => $p{run}) : ()),
        );
        return 0;
    }
}

# Resource exposing two distinct service methods. Useful for asserting
# that one resource can stand up multiple services as long as the names
# don't collide.
{

    package Test::TwoServices;
    use Object::HashBase qw{<pids};
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub init { $_[0]->{+PIDS} //= [] }

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub _track_one {
        my ($self, $method, %p) = @_;
        my $pid = shift @{$self->{+PIDS}} // 92_000;
        $p{harness}->track_resource_service(
            pid      => $pid,
            resource => $self,
            method   => $method,
            name     => $p{name},
            log_path => $p{log_path},
            scope    => $p{scope},
            (defined $p{run} ? (run => $p{run}) : ()),
        );
        return 0;
    }

    sub service_alpha { my $self = shift; $self->_track_one('service_alpha', @_) }
    sub service_beta  { my $self = shift; $self->_track_one('service_beta',  @_) }
}

subtest 'global service lays down services/<name>.jsonl + passes name + log_path' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new(pids => [93_001]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    my @all;
    for (1 .. 3) {
        push @all => Test2::Harness2::Resource::JobCount->new(slots => 1);
    }

    $h->_start_resource_services([$res], scope => 'global');

    my $expected = "$dir/services/foo.jsonl";
    ok(-e $expected, "log file created at $expected");

    is($res->last_args->{name},     'foo',     'name argument derived from method');
    is($res->last_args->{log_path}, $expected, 'log_path argument matches file on disk');
    is($res->last_args->{scope},    'global',  'scope argument set');

    my $svc = $h->{resource_services}{93_001};
    ok($svc, 'tracking entry exists');
    is($svc->{name},     'foo',     'tracking entry records name');
    is($svc->{log_path}, $expected, 'tracking entry records log_path');
};

subtest 'per-run service lays down runs/<run_id>/services/<name>.jsonl' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my $res = Test::OneService->new(pids => [93_101]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-alpha', resources => [$res]);

    $h->_start_resource_services([$res], scope => 'run', run => $run);

    my $expected = "$dir/runs/r-alpha/services/foo.jsonl";
    ok(-e $expected, "log file created at $expected");
    is($res->last_args->{log_path}, $expected, 'log_path points to per-run dir');
    is($res->last_args->{scope},    'run',     'scope argument is run');

    my $svc = $h->{resource_services}{93_101};
    is($svc->{scope},    'run',     'tracking entry has run scope');
    is($svc->{log_path}, $expected, 'tracking entry points at per-run file');
    ref_is($svc->{run}, $run, 'tracking entry stores run ref');
};

subtest 'in-batch global name collision across two resources is rejected' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $res1 = Test::OneService->new;
    my $res2 = Test::OtherService->new;
    my $h    = Test2::Harness2->new(workdir => $dir, resources => [$res1, $res2]);

    my $ok  = eval { $h->_start_resource_services([$res1, $res2], scope => 'global'); 1 };
    my $err = $@;
    ok(!$ok, 'start croaked');
    like($err, qr/collides with in-batch service 'service_foo'/, 'explains the collision');
    is(scalar keys %{$h->{resource_services}}, 0, 'no services tracked after failure');
    ok(
        !-e "$dir/services/foo.jsonl" || -z "$dir/services/foo.jsonl",
        'log file empty or absent (first service was touched before collision detected)'
    );
};

subtest 'per-run name collision within the same run is rejected' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $h    = Test2::Harness2->new(workdir => $dir);
    my $res1 = Test::OneService->new;
    my $res2 = Test::OtherService->new;
    my $run  = Test2::Harness2::Run->new(run_id => 'r-dup', resources => [$res1, $res2]);

    my $ok = eval {
        $h->_start_resource_services([$res1, $res2], scope => 'run', run => $run);
        1;
    };
    my $err = $@;
    ok(!$ok, 'per-run start croaked');
    like($err, qr/collides with in-batch service/, 'explains the collision');
};

subtest 'name is allowed to collide across scopes (global vs run)' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $glob = Test::OneService->new(pids => [93_201]);
    my $runr = Test::OtherService->new(pids => [93_202]);
    my $h    = Test2::Harness2->new(workdir => $dir, resources => [$glob]);
    my $run  = Test2::Harness2::Run->new(run_id => 'r-cross', resources => [$runr]);

    $h->_start_resource_services([$glob], scope => 'global');
    my $ok = eval {
        $h->_start_resource_services([$runr], scope => 'run', run => $run);
        1;
    };
    my $err = $@;
    ok($ok,                                       'run-scoped reuse of a global name is allowed') or diag $err;
    ok(-e "$dir/services/foo.jsonl",              'global log at services/foo.jsonl');
    ok(-e "$dir/runs/r-cross/services/foo.jsonl", 'run log at runs/r-cross/services/foo.jsonl');
};

subtest 'names are allowed to collide across different runs' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $h    = Test2::Harness2->new(workdir => $dir);
    my $ra   = Test::OneService->new(pids => [93_301]);
    my $rb   = Test::OtherService->new(pids => [93_302]);
    my $runA = Test2::Harness2::Run->new(run_id => 'r-A', resources => [$ra]);
    my $runB = Test2::Harness2::Run->new(run_id => 'r-B', resources => [$rb]);

    $h->_start_resource_services([$ra], scope => 'run', run => $runA);
    my $ok = eval {
        $h->_start_resource_services([$rb], scope => 'run', run => $runB);
        1;
    };
    my $err = $@;
    ok($ok,                                   'separate runs may share service names') or diag $err;
    ok(-e "$dir/runs/r-A/services/foo.jsonl", 'run A has its own foo.jsonl');
    ok(-e "$dir/runs/r-B/services/foo.jsonl", 'run B has its own foo.jsonl');
};

subtest "harness's own NAME is reserved in global scope" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new;
    my $h   = Test2::Harness2->new(workdir => $dir, name => 'foo', resources => [$res]);

    my $ok  = eval { $h->_start_resource_services([$res], scope => 'global'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks');
    like($err, qr/reserved by the harness/, 'error mentions reservation');
};

subtest 'harness name is not reserved in per-run scope' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, name => 'foo');
    my $res = Test::OneService->new(pids => [93_400]);
    my $run = Test2::Harness2::Run->new(run_id => 'r-ns', resources => [$res]);

    my $ok = eval { $h->_start_resource_services([$res], scope => 'run', run => $run); 1 };
    ok($ok,                                    'per-run usage of the harness-reserved name is permitted');
    ok(-e "$dir/runs/r-ns/services/foo.jsonl", 'per-run log created regardless of global reservation');
};

subtest 'one resource with two services gets two distinct log files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::TwoServices->new(pids => [93_500, 93_501]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->_start_resource_services([$res], scope => 'global');

    ok(-e "$dir/services/alpha.jsonl", 'alpha log created');
    ok(-e "$dir/services/beta.jsonl",  'beta log created');

    my %by_name = map { ($_->{name} => $_) } values %{$h->{resource_services}};
    ok(exists $by_name{alpha}, 'alpha service tracked');
    ok(exists $by_name{beta},  'beta service tracked');
    isnt($by_name{alpha}{log_path}, $by_name{beta}{log_path}, 'log paths differ');
};

subtest 'restart reuses the same name + log_path' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new(pids => [93_601, 93_602]);
    $res->{_resource_returns} = [1, 1];    # unused; Test::OneService returns 0, see below

    # Use Test::Restart::Res-style inline resource so we can drive the
    # restart path deterministically. Test::OneService returns 0 (not
    # restartable), which isn't what we want here.
    my $R = do {

        package Test::RestartLog::Res;
        use Object::HashBase qw{<pids};
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Resource';
        sub init      { $_[0]->{+PIDS} //= [] }
        sub available { 1 }
        sub assign    { 1 }
        sub release   { 1 }
        sub status    { {} }

        sub service_foo {
            my ($self, %p) = @_;
            my $pid = shift @{$self->{+PIDS}};
            $p{harness}->track_resource_service(
                pid      => $pid,
                resource => $self,
                method   => 'service_foo',
                name     => $p{name},
                log_path => $p{log_path},
                scope    => $p{scope},
            );
            return 1;
        }
        __PACKAGE__;
    };

    my $r = $R->new(pids => [93_701, 93_702]);
    my $h = Test2::Harness2->new(workdir => $dir, resources => [$r]);
    $h->_start_resource_services([$r], scope => 'global');

    my $expected = "$dir/services/foo.jsonl";
    is($h->{resource_services}{93_701}{log_path}, $expected, 'initial log_path set');

    # Simulate the original pid exiting; restart picks up pid 93_702.
    $h->run_on_pid(93_701, 0);

    ok(!exists $h->{resource_services}{93_701}, 'old pid dropped');
    ok(exists $h->{resource_services}{93_702},  'new pid tracked');
    is($h->{resource_services}{93_702}{name},     'foo',     'restart preserves name');
    is($h->{resource_services}{93_702}{log_path}, $expected, 'restart preserves log_path');
};

subtest 'track_resource_service requires enough info to derive a name' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new;
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $ok = eval {
        $h->track_resource_service(pid => 9_999_801, resource => $res);
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaks without method or name');
    like($err, qr/'name'/, 'error mentions name');
};

subtest 'track_resource_service rejects a duplicate name directly' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new;
    my $h   = Test2::Harness2->new(workdir => $dir);

    $h->track_resource_service(
        pid      => 9_999_901,
        resource => $res,
        method   => 'service_foo',
    );
    my $ok = eval {
        $h->track_resource_service(
            pid      => 9_999_902,
            resource => Test::OtherService->new,
            method   => 'service_foo',
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'direct duplicate across resources rejected');
    like($err, qr/already in use/, 'error mentions reuse');
};

subtest "method named 'service_' with an empty suffix is rejected" => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::OneService->new;
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $ok = eval {
        $h->track_resource_service(
            pid      => 9_999_950,
            resource => $res,
            method   => 'service_',
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaked');
    like($err, qr/cannot derive service name/, 'error mentions derivation failure');
};

done_testing;
