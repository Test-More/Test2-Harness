use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;
use App::Yath2::Log::Directory;

# {{{ run_producers / job_producers basics

subtest 'run_producers and job_producers' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Layout: one run, two jobs each with one try.
    make_path("$dir/runs/1/jobs/1/0");
    make_path("$dir/runs/1/jobs/2/0");

    # spec.jsonl files for both jobs -- assert artifact_refs discovers them.
    open my $s1, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open: $!";
    print $s1 qq[{"job_id":"1","try":0}\n];
    close $s1;
    open my $s2, '>', "$dir/runs/1/jobs/2/0/spec.jsonl" or die "open: $!";
    print $s2 qq[{"job_id":"2","try":0}\n];
    close $s2;

    # Job 1 sealed, job 2 still partial. Run not sealed yet.
    open my $sm, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open: $!";
    print $sm encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sm;

    # LIVE present => live mode (otherwise sealed log treats everything sealed).
    open my $lfh, '>', "$dir/LIVE" or die "open: $!";
    print $lfh "1\n";
    close $lfh;

    my $log = App::Yath2::Log->new(live => $dir);

    my @runs = $log->run_producers->all;
    is(scalar(@runs),   1,         'one run');
    is($runs[0]->id,    '1',       'run id');
    is($runs[0]->state, 'partial', 'run partial (no .sealed)');

    my @jobs = $log->job_producers('1')->all;
    is(scalar(@jobs), 2, 'two jobs');
    my ($j1, $j2) = sort { $a->id <=> $b->id } @jobs;
    is($j1->state, 'sealed',  'job 1 sealed (has .sealed)');
    is($j2->state, 'partial', 'job 2 partial');
    is($j1->pass,  1,         'pass from .sealed');

    # Verify spec.jsonl artifact refs are discovered.
    ok(defined $j1->artifact_refs->{spec}, 'job 1 spec artifact ref present');
    ok(defined $j2->artifact_refs->{spec}, 'job 2 spec artifact ref present');

    # Seal run.
    open my $rsm, '>', "$dir/runs/1/.sealed" or die "open: $!";
    print $rsm encode_json({sealed_at => 200, final_state => 'completed', pass => 0, exit => 1});
    close $rsm;

    @runs = $log->run_producers->all;
    is($runs[0]->state, 'sealed', 'run sealed after .sealed appears');
    is($runs[0]->pass,  0,        'pass from .sealed');
    is($runs[0]->exit,  1,        'exit from .sealed');
};

# }}}

# {{{ service_producers

subtest 'service_producers (run-scoped and global)' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Run-scoped service: runs/1/services/preload/ (sealed)
    make_path("$dir/runs/1/services/preload");
    open my $fh, '>', "$dir/runs/1/services/preload/.sealed" or die "open: $!";
    print $fh encode_json({started_at => 10, sealed_at => 50});
    close $fh;

    # Global service: services/audit/ (no .sealed => partial in live mode)
    make_path("$dir/services/audit");

    # LIVE marker => live mode.
    open my $lfh, '>', "$dir/LIVE" or die "open: $!";
    print $lfh "1\n";
    close $lfh;

    my $log = App::Yath2::Log::Directory->new(path => $dir, live => 1);

    # Run must exist for run-scoped services() call.
    make_path("$dir/runs/1");

    # Run-scoped services.
    my @svc_run = $log->service_producers('1')->all;
    is(scalar(@svc_run),        1,         'one run-scoped service');
    is($svc_run[0]->id,         'preload', 'service id');
    is($svc_run[0]->state,      'sealed',  'run-scoped service sealed (has .sealed)');
    is($svc_run[0]->parent_id,  '1',       'parent_id is run id');
    is($svc_run[0]->run_id,     '1',       'run_id set');
    is($svc_run[0]->started_at, 10,        'started_at from .sealed');
    is($svc_run[0]->ended_at,   50,        'ended_at (sealed_at) from .sealed');

    # Global services.
    my @svc_global = $log->service_producers->all;
    is(scalar(@svc_global),   1,         'one global service');
    is($svc_global[0]->id,    'audit',   'global service id');
    is($svc_global[0]->state, 'partial', 'global service partial (no .sealed, live mode)');
    ok(!defined $svc_global[0]->parent_id, 'no parent_id for global service');
    ok(!defined $svc_global[0]->run_id,    'no run_id for global service');
};

# }}}

# {{{ collector_producers

subtest 'collector_producers' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # A sealed collector.
    make_path("$dir/collectors/uuid-xyz");
    open my $fh, '>', "$dir/collectors/uuid-xyz/.sealed" or die "open: $!";
    print $fh encode_json({started_at => 5, sealed_at => 20});
    close $fh;

    # LIVE marker for live mode.
    open my $lfh, '>', "$dir/LIVE" or die "open: $!";
    print $lfh "1\n";
    close $lfh;

    my $log = App::Yath2::Log::Directory->new(path => $dir, live => 1);

    my @cols = $log->collector_producers->all;
    is(scalar(@cols),   1,          'one collector');
    is($cols[0]->id,    'uuid-xyz', 'collector id');
    is($cols[0]->state, 'sealed',   'collector sealed (has .sealed)');
    ok(!defined $cols[0]->parent_id, 'no parent_id');
    ok(!defined $cols[0]->run_id,    'no run_id');
};

# }}}

# {{{ sealed log path (no LIVE file => all producers sealed regardless of .sealed marker)

subtest 'sealed log (no LIVE file)' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # One run, one job try; no .sealed markers anywhere.
    make_path("$dir/runs/1/jobs/1/0");
    make_path("$dir/runs/1/services/bg");
    make_path("$dir/services/global");
    make_path("$dir/collectors/cid1");

    # No LIVE file => sealed/static log.
    my $log = App::Yath2::Log::Directory->new(path => $dir, live => 0);

    my @runs = $log->run_producers->all;
    is($runs[0]->state, 'sealed', 'run sealed in static log (no .sealed marker needed)');

    my @jobs = $log->job_producers('1')->all;
    is($jobs[0]->state, 'sealed', 'job sealed in static log (no .sealed marker needed)');

    my @svc_run = $log->service_producers('1')->all;
    is($svc_run[0]->state, 'sealed', 'run-scoped service sealed in static log');

    my @svc_global = $log->service_producers->all;
    is($svc_global[0]->state, 'sealed', 'global service sealed in static log');

    my @cols = $log->collector_producers->all;
    is($cols[0]->state, 'sealed', 'collector sealed in static log');
};

# }}}

# {{{ started_at / ended_at round-trip

subtest 'started_at and ended_at from .sealed content' => sub {
    my $dir = tempdir(CLEANUP => 1);

    make_path("$dir/runs/1");

    open my $fh, '>', "$dir/runs/1/.sealed" or die "open: $!";
    print $fh encode_json({started_at => 50, sealed_at => 100, pass => 1, exit => 0});
    close $fh;

    my $log  = App::Yath2::Log::Directory->new(path => $dir, live => 0);
    my @runs = $log->run_producers->all;

    is($runs[0]->started_at, 50,  'started_at round-trips from .sealed');
    is($runs[0]->ended_at,   100, 'ended_at (sealed_at) round-trips from .sealed');
    is($runs[0]->pass,       1,   'pass round-trips from .sealed');
    is($runs[0]->exit,       0,   'exit round-trips from .sealed');
};

# }}}

done_testing;
