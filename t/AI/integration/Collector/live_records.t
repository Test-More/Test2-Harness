use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# Unit-style integration test: verify that _emit_collector_start and
# _emit_collector_end append LIVE producer records unconditionally,
# regardless of whether an IPC lifecycle target is present.
#
# Strategy: construct Collector instances directly (no fork), install a
# fake IPC client that records sends, call the emission methods, then
# read the LIVE file and assert the appended records are correct.

use Test2::Harness2::Collector;

# Minimal fake IPC client so _send_to does not die trying to connect.
{

    package t2h2::FakeIPCClient;

    sub set_send_blocking     { return }
    sub peer_active           { 1 }
    sub have_pending_sends    { 0 }
    sub drain_pending         { 0 }
    sub have_writable_handles { 0 }
    sub writable_handles      { () }
    sub disconnect            { return }

    sub try_send_message {
        my ($self, $target, $content) = @_;
        push @{$self->{sent}}, [$target, $content];
        return 1;
    }
    sub send_message { goto &try_send_message }
}

sub install_fake_client {
    my ($self) = @_;
    my @sent;
    $self->{_ipc_client}       = bless {sent => \@sent}, 't2h2::FakeIPCClient';
    $self->{_ipc_target_ready} = {};
    $self->{_ipc_target_seen}  = {};
    return \@sent;
}

sub read_live_records {
    my ($dir) = @_;
    my $path = "$dir/LIVE";
    return () unless -f $path;
    open my $fh, '<', $path or die "open $path: $!";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return map { decode_json($_) } grep { length $_ } @lines;
}

# ─── Job collector ───────────────────────────────────────────────────────────

subtest 'job collector emits producer open/close records to LIVE' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $c   = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_run     => 'run-r0',
        ipc_parent  => 'run-r0',
        type        => 'Job',
        id          => 5,
        run_id      => 2,
        job_try     => 0,
        logdir      => $dir,
        launch      => ['perl', '-e', 1],
        child_pid   => 9999,
        spec        => {file => 'fake.t'},
    );
    install_fake_client($c);

    $c->_emit_collector_start({});
    $c->_emit_collector_end(0);

    my @recs = read_live_records($dir);
    is(scalar @recs, 2, 'two LIVE records written (open + close)');

    my ($open, $close) = @recs;

    is($open->{k},     'producer', 'open record: k=producer');
    is($open->{kind},  'job',      'open record: kind=job');
    is($open->{id},    5,          'open record: id=job id');
    is($open->{state}, 'open',     'open record: state=open');
    ok(defined $open->{ts}, 'open record: ts present');

    is($close->{k},     'producer', 'close record: k=producer');
    is($close->{kind},  'job',      'close record: kind=job');
    is($close->{id},    5,          'close record: id=job id');
    is($close->{state}, 'close',    'close record: state=close');
    ok(defined $close->{ts}, 'close record: ts present');
};

# ─── Run collector ───────────────────────────────────────────────────────────

subtest 'run collector emits producer open/close records to LIVE' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $c   = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        ipc_run     => undef,
        type        => 'Run',
        id          => 3,
        run_id      => 3,
        logdir      => $dir,
        launch      => ['perl', '-e', 1],
        child_pid   => 8888,
    );
    install_fake_client($c);

    $c->_emit_collector_start({});
    $c->_emit_collector_end(undef);

    my @recs = read_live_records($dir);
    is(scalar @recs, 2, 'two LIVE records written');

    is($recs[0]->{kind},  'run',  'open record: kind=run');
    is($recs[0]->{id},    3,      'open record: id=run_id');
    is($recs[0]->{state}, 'open', 'open record: state=open');

    is($recs[1]->{kind},  'run',   'close record: kind=run');
    is($recs[1]->{id},    3,       'close record: id=run_id');
    is($recs[1]->{state}, 'close', 'close record: state=close');
};

# ─── Service collector ───────────────────────────────────────────────────────

subtest 'service collector emits producer open/close records to LIVE' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $c   = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        ipc_run     => undef,
        type        => 'Service',
        id          => 'svc-db',
        logdir      => $dir,
        launch      => ['perl', '-e', 1],
        child_pid   => 7777,
    );
    install_fake_client($c);

    $c->_emit_collector_start({});
    $c->_emit_collector_end(undef);

    my @recs = read_live_records($dir);
    is(scalar @recs, 2, 'two LIVE records written');

    is($recs[0]->{kind},  'service', 'open record: kind=service');
    is($recs[0]->{id},    'svc-db',  'open record: id=service name');
    is($recs[0]->{state}, 'open',    'open record: state=open');

    is($recs[1]->{kind},  'service', 'close record: kind=service');
    is($recs[1]->{id},    'svc-db',  'close record: id=service name');
    is($recs[1]->{state}, 'close',   'close record: state=close');
};

# ─── Top-level harness collector (no IPC target) ─────────────────────────────

subtest 'top-level harness collector emits LIVE records even with no IPC target' => sub {
    # The harness-level collector has ipc_parent=undef and ipc_run=undef,
    # so _lifecycle_ipc_target returns undef and IPC emission is skipped.
    # The LIVE append must still happen unconditionally.
    my $dir = tempdir(CLEANUP => 1);
    my $c   = Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => undef,
        ipc_run     => undef,
        type        => 'Service',
        id          => 'harness',
        logdir      => $dir,
        launch      => ['perl', '-e', 1],
        child_pid   => 6666,
    );
    # No fake client installed -- _send_to returns early because target=undef.

    $c->_emit_collector_start({});
    $c->_emit_collector_end(undef);

    my @recs = read_live_records($dir);
    is(scalar @recs,      2,         'two LIVE records even without IPC target');
    is($recs[0]->{state}, 'open',    'first record is open');
    is($recs[1]->{state}, 'close',   'second record is close');
    is($recs[0]->{kind},  'service', 'kind=service for harness service collector');
    is($recs[0]->{id},    'harness', 'id=service name');
};

# ─── LIVE records accumulate across multiple emit calls ───────────────────────

subtest 'LIVE records from multiple emit calls accumulate in one file' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $mk_job = sub {
        my ($id) = @_;
        my $c = Test2::Harness2::Collector->new(
            ipcm_info   => {},
            ipc_harness => 'harness',
            ipc_run     => 'run-r0',
            ipc_parent  => 'run-r0',
            type        => 'Job',
            id          => $id,
            run_id      => 0,
            job_try     => 0,
            logdir      => $dir,
            launch      => ['perl', '-e', 1],
            child_pid   => 1000 + $id,
            spec        => {file => "job$id.t"},
        );
        install_fake_client($c);
        return $c;
    };

    my $c1 = $mk_job->(1);
    my $c2 = $mk_job->(2);

    $c1->_emit_collector_start({});
    $c2->_emit_collector_start({});
    $c1->_emit_collector_end(0);
    $c2->_emit_collector_end(0);

    my @recs = read_live_records($dir);
    is(scalar @recs, 4, 'four LIVE records: two opens + two closes');

    my @opens  = grep { $_->{state} eq 'open' } @recs;
    my @closes = grep { $_->{state} eq 'close' } @recs;
    is(scalar @opens,  2, 'two open records');
    is(scalar @closes, 2, 'two close records');

    my %open_ids  = map { $_->{id} => 1 } @opens;
    my %close_ids = map { $_->{id} => 1 } @closes;
    ok($open_ids{1},  'job 1 open present');
    ok($open_ids{2},  'job 2 open present');
    ok($close_ids{1}, 'job 1 close present');
    ok($close_ids{2}, 'job 2 close present');
};

done_testing;
