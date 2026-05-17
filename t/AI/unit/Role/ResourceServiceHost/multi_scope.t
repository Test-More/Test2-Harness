use Test2::V0;
use File::Temp qw/tempdir/;

# Stub host that consumes the role so we can exercise the cross-scope
# reservation logic without spinning up a real harness or a real ipc
# bus. Models a host whose own scope is 'global' (as the harness does
# today) but which dispatches start_resource_services calls for both
# scope=>'global' and scope=>'run'.

package T2H2_TestHost {
    use strict;
    use warnings;
    use Object::HashBase qw{
        <workdir
        <name
        <ipcm_info
        <service_host_scope
        <service_host_run
        <service_host_logdir
        <service_host_log_name
        <pid_index
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::ResourceServiceHost';

    sub init {
        my $self = shift;
        $self->{+NAME}                  //= 'harness';
        $self->{+SERVICE_HOST_SCOPE}    //= 'global';
        $self->{+SERVICE_HOST_LOGDIR}   //= $self->{+WORKDIR};
        $self->{+SERVICE_HOST_LOG_NAME} //= $self->{+NAME};
        $self->{+PID_INDEX}             //= T2H2_TestPidIndex->new;
    }

    sub emit_service_event { }
}

# Stub pid index: this test exercises name/scope reservation, so the
# index needs a real resource_services slot the role can read/write
# through. The tracked/forgotten notifications are still no-ops here.
package T2H2_TestPidIndex {
    sub new { bless { resource_services => {} }, shift }
    sub resource_services          { $_[0]->{resource_services} }
    sub resource_service_tracked   { }
    sub resource_service_forgotten { }
}

package T2H2_TestRun {
    sub new { my ($c, %p) = @_; bless { %p }, $c }
    sub run_id { $_[0]->{run_id} }
}

package T2H2_TestRes {
    sub new { my ($c, %p) = @_; bless { %p }, $c }
    sub resource_name { $_[0]->{name} // 'res' }
    sub services { $_[0]->{services} // [] }
    sub mark_permanent_broken { $_[0]->{permanent_broken} = 1 }
    sub is_permanent_broken { $_[0]->{permanent_broken} ? 1 : 0 }
    sub mark_broken { $_[0]->{broken} = 1 }
    sub is_broken { $_[0]->{broken} ? 1 : 0 }
}

package T2H2_TestSvc_Restart {
    # Don't actually consume the role here; we only need the
    # `restartable` class method so track_resource_service can snapshot
    # it. The role's other contract (run/name/etc.) only matters in
    # _start_service_entry, which we are not exercising in these
    # tests.
    sub restartable { 1 }
}

package main;

sub _new_host {
    my $dir = tempdir(CLEANUP => 1);
    return T2H2_TestHost->new(workdir => $dir);
}

subtest cross_scope_no_reservation_collision => sub {
    my $host = _new_host;
    my $res  = T2H2_TestRes->new(name => 'cpu');
    my $run  = T2H2_TestRun->new(run_id => 'R1');

    # The host's own log name is 'harness'. A global-scope service
    # named 'harness' would collide; a run-scope service named
    # 'harness' must NOT, because it's a different scope.
    my $ok = eval {
        $host->_assert_service_name_unused(
            name     => 'harness',
            scope    => 'run',
            run      => $run,
            resource => $res,
            class    => 'T2H2_TestSvc_Restart',
        );
        1;
    };
    ok($ok, 'host log name reserved only in host scope') or diag $@;

    my $bad = eval {
        $host->_assert_service_name_unused(
            name     => 'harness',
            scope    => 'global',
            run      => undef,
            resource => $res,
            class    => 'T2H2_TestSvc_Restart',
        );
        1;
    };
    ok(!$bad, 'host log name still reserved in own (global) scope');
    like($@, qr/reserved by the global service/, 'expected error');
};

subtest same_name_across_runs_allowed => sub {
    my $host = _new_host;
    my $res  = T2H2_TestRes->new(name => 'cpu');
    my $run_a = T2H2_TestRun->new(run_id => 'A');
    my $run_b = T2H2_TestRun->new(run_id => 'B');

    $host->track_resource_service(
        pid           => 11_001,
        resource      => $res,
        service_class => 'T2H2_TestSvc_Restart',
        name          => 'percpu',
        scope         => 'run',
        run           => $run_a,
    );

    my $ok = eval {
        $host->track_resource_service(
            pid           => 11_002,
            resource      => $res,
            service_class => 'T2H2_TestSvc_Restart',
            name          => 'percpu',
            scope         => 'run',
            run           => $run_b,
        );
        1;
    };
    ok($ok, 'same name allowed across distinct runs') or diag $@;
};

subtest within_run_scope_name_collision => sub {
    my $host = _new_host;
    my $res  = T2H2_TestRes->new(name => 'cpu');
    my $run  = T2H2_TestRun->new(run_id => 'A');

    $host->track_resource_service(
        pid           => 22_001,
        resource      => $res,
        service_class => 'T2H2_TestSvc_Restart',
        name          => 'percpu',
        scope         => 'run',
        run           => $run,
    );

    my $second_res = T2H2_TestRes->new(name => 'mem');
    my $bad = eval {
        $host->track_resource_service(
            pid           => 22_002,
            resource      => $second_res,
            service_class => 'T2H2_TestSvc_Restart',
            name          => 'percpu',
            scope         => 'run',
            run           => $run,
        );
        1;
    };
    ok(!$bad, 'collision rejected within (scope, run, name)');
    like($@, qr/already in use in run scope for this run/, 'error message identifies run scope');
};

subtest log_path_segregation => sub {
    my $host = _new_host;
    my $run  = T2H2_TestRun->new(run_id => 'A');

    my $glob = $host->_resource_service_log_path(
        name  => 'cpu',
        scope => 'global',
    );
    my $rs   = $host->_resource_service_log_path(
        name  => 'cpu',
        scope => 'run',
        run   => $run,
    );

    like($glob, qr{/services/cpu/events\.jsonl$}, 'global log path');
    like($rs,   qr{/runs/A/services/cpu/events\.jsonl$}, 'per-run log path');
    isnt($glob, $rs, 'paths differ');
};

done_testing;
