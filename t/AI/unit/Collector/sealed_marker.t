use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2::Collector;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Minimal fake IPC client so _emit_collector_end's _send_to call does
# not explode when IPC targets are defined.
{

    package t2h2::FakeIPCClient;
    sub set_send_blocking     { return }
    sub peer_active           { 1 }
    sub have_pending_sends    { 0 }
    sub drain_pending         { 0 }
    sub have_writable_handles { 0 }
    sub writable_handles      { () }
    sub disconnect            { return }
    sub try_send_message      { 1 }
    sub send_message          { 1 }
}

sub seed_live {
    my ($dir) = @_;
    open my $fh, '>', "$dir/LIVE" or die "open LIVE: $!";
    print $fh "1\n";
    close $fh;
}

sub install_fake_ipc {
    my ($c) = @_;
    $c->{_ipc_client}       = bless {}, 't2h2::FakeIPCClient';
    $c->{_ipc_target_ready} = {};
    $c->{_ipc_target_seen}  = {};
}

sub read_sealed {
    my ($dir, $rel) = @_;
    my $path = "$dir/$rel/.sealed";
    open my $fh, '<', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    chomp $raw;
    return decode_json($raw);
}

# ------------------------------------------------------------------ #
# TYPE=Job                                                            #
# ------------------------------------------------------------------ #

subtest 'Job collector writes .sealed at runs/<run_id>/jobs/<id>/<try>' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-0',
        ipc_parent  => 'run-0',
        type        => 'Job',
        id          => 42,
        run_id      => 7,
        job_try     => 2,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    my $rel = "runs/7/jobs/42/2";
    mkdir "$dir/runs",             0755;
    mkdir "$dir/runs/7",           0755;
    mkdir "$dir/runs/7/jobs",      0755;
    mkdir "$dir/runs/7/jobs/42",   0755;
    mkdir "$dir/runs/7/jobs/42/2", 0755;

    # Call _emit_collector_end, which should write .sealed.
    my $child_exit = 0 << 8;    # exit 0
    $c->_emit_collector_end($child_exit);

    my $data = read_sealed($dir, $rel);
    ok(defined $data,          '.sealed file exists at expected path');
    ok($data->{sealed_at} > 0, 'sealed_at is a positive timestamp');
    is($data->{final_state}, 'completed', 'final_state=completed');
    ok(exists $data->{exit}, 'exit key present');
};

# ------------------------------------------------------------------ #
# TYPE=Run                                                            #
# ------------------------------------------------------------------ #

subtest 'Run collector writes .sealed at runs/<run_id>' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Run',
        id          => 3,
        run_id      => 3,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    mkdir "$dir/runs",   0755;
    mkdir "$dir/runs/3", 0755;

    $c->_emit_collector_end(undef);

    my $data = read_sealed($dir, 'runs/3');
    ok(defined $data,          '.sealed file exists at runs/3');
    ok($data->{sealed_at} > 0, 'sealed_at is numeric');
    is($data->{final_state}, 'completed', 'final_state=completed');
};

# ------------------------------------------------------------------ #
# TYPE=Service (run-scoped)                                           #
# ------------------------------------------------------------------ #

subtest 'Service (run-scoped) collector writes .sealed at runs/<run_id>/services/<name>' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Service',
        id          => 'my-svc',
        run_id      => 5,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    mkdir "$dir/runs",                   0755;
    mkdir "$dir/runs/5",                 0755;
    mkdir "$dir/runs/5/services",        0755;
    mkdir "$dir/runs/5/services/my-svc", 0755;

    $c->_emit_collector_end(undef);

    my $data = read_sealed($dir, 'runs/5/services/my-svc');
    ok(defined $data,          '.sealed file exists at run-scoped service path');
    ok($data->{sealed_at} > 0, 'sealed_at is numeric');
    is($data->{final_state}, 'completed', 'final_state=completed');
};

# ------------------------------------------------------------------ #
# TYPE=Service (global)                                               #
# ------------------------------------------------------------------ #

subtest 'Service (global) collector writes .sealed at services/<name>' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Service',
        id          => 'global-svc',
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    mkdir "$dir/services",            0755;
    mkdir "$dir/services/global-svc", 0755;

    $c->_emit_collector_end(undef);

    my $data = read_sealed($dir, 'services/global-svc');
    ok(defined $data,          '.sealed file exists at global service path');
    ok($data->{sealed_at} > 0, 'sealed_at is numeric');
    is($data->{final_state}, 'completed', 'final_state=completed');
};

# ------------------------------------------------------------------ #
# Top-level harness collector does NOT write .sealed                  #
# ------------------------------------------------------------------ #

subtest 'Top-level harness collector (no ipc_parent, no ipc_run) does not write .sealed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    # The harness root is a Run collector with ipc_harness set (required)
    # but no ipc_parent and no ipc_run. _is_top_level_harness detects this
    # combination and suppresses .sealed writes so the lifecycle root never
    # seals itself.
    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'self',                # required attribute — set to something
        type        => 'Run',
        id          => 1,
        run_id      => 1,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
        # ipc_parent and ipc_run intentionally omitted
    );

    mkdir "$dir/runs",   0755;
    mkdir "$dir/runs/1", 0755;

    # No fake IPC needed — harness collector skips IPC send entirely.
    $c->_emit_collector_end(undef);

    my $path = "$dir/runs/1/.sealed";
    ok(!-e $path, '.sealed not written for harness-root collector');
};

# ------------------------------------------------------------------ #
# Existing-file-wins: second call does not clobber first .sealed      #
# ------------------------------------------------------------------ #

subtest 'Existing-file-wins: second _emit_collector_end does not clobber .sealed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Run',
        id          => 9,
        run_id      => 9,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    mkdir "$dir/runs",   0755;
    mkdir "$dir/runs/9", 0755;

    $c->_emit_collector_end(undef);

    my $first = read_sealed($dir, 'runs/9');
    ok(defined $first, 'first .sealed written');

    # Simulate a second invocation (finalization sweep). The content
    # must remain from the first write.
    $c->_emit_collector_end(undef);

    my $second = read_sealed($dir, 'runs/9');
    is($second->{sealed_at}, $first->{sealed_at}, 'sealed_at unchanged — first write wins');
};

# ------------------------------------------------------------------ #
# pass + exit forwarded when present                                  #
# ------------------------------------------------------------------ #

subtest 'pass and exit fields forwarded into .sealed' => sub {
    my $dir = tempdir(CLEANUP => 1);
    seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-0',
        ipc_parent  => 'run-0',
        type        => 'Job',
        id          => 1,
        run_id      => 0,
        job_try     => 1,
        logdir      => $dir,
        launch      => ['perl', '-e', '1'],
    );
    install_fake_ipc($c);

    # Stub a passing auditor.
    {

        package t2h2::PassAuditor;
        sub new  { bless {}, shift }
        sub pass { 1 }
    }
    $c->{Test2::Harness2::Collector::AUDITOR()} = t2h2::PassAuditor->new;

    mkdir "$dir/runs",            0755;
    mkdir "$dir/runs/0",          0755;
    mkdir "$dir/runs/0/jobs",     0755;
    mkdir "$dir/runs/0/jobs/1",   0755;
    mkdir "$dir/runs/0/jobs/1/1", 0755;

    my $child_exit = 0 << 8;    # exit 0
    $c->_emit_collector_end($child_exit);

    my $data = read_sealed($dir, 'runs/0/jobs/1/1');
    ok(defined $data,        '.sealed written');
    ok(exists $data->{exit}, 'exit present in .sealed');
    is($data->{exit}, $child_exit, 'exit value matches wait status');
    ok(exists $data->{pass}, 'pass present in .sealed for Job with auditor');
    is($data->{pass}, 1, 'pass=1 from auditor');
};

done_testing;
