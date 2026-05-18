use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep stat/;

# Integration test: verify that _emit_collector_start and _emit_collector_end
# bump LIVE's mtime (via _live_bump) regardless of whether an IPC lifecycle
# target is present. The file content stays as the original "1\n" sentinel.

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

sub seed_live {
    my ($dir) = @_;
    open my $fh, '>', "$dir/LIVE" or die "open $dir/LIVE: $!";
    print $fh "1\n";
    close $fh;
    return (stat "$dir/LIVE")[9];
}

# ─── Job collector ───────────────────────────────────────────────────────────

subtest 'job collector bumps LIVE mtime on start and end' => sub {
    my $dir   = tempdir(CLEANUP => 1);
    my $mtime = seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
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

    sleep 0.05;
    $c->_emit_collector_start({});
    my $after_start = (stat "$dir/LIVE")[9];
    ok($after_start > $mtime, 'mtime bumped after _emit_collector_start');

    sleep 0.05;
    $c->_emit_collector_end(0);
    my $after_end = (stat "$dir/LIVE")[9];
    ok($after_end > $after_start, 'mtime bumped again after _emit_collector_end');

    # Content still unchanged.
    open my $fh, '<', "$dir/LIVE" or die;
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "1\n", 'LIVE content still the original sentinel');
};

# ─── Top-level harness collector (no IPC target) ─────────────────────────────

subtest 'top-level harness collector bumps LIVE mtime even without IPC target' => sub {
    # ipc_parent=undef means _lifecycle_ipc_target returns undef and IPC
    # emission is skipped, but _live_bump must still fire unconditionally.
    my $dir   = tempdir(CLEANUP => 1);
    my $mtime = seed_live($dir);

    my $c = Test2::Harness2::Collector->new(
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

    sleep 0.05;
    $c->_emit_collector_start({});
    my $after_start = (stat "$dir/LIVE")[9];
    ok($after_start > $mtime, 'mtime bumped on start even with no IPC target');

    sleep 0.05;
    $c->_emit_collector_end(undef);
    my $after_end = (stat "$dir/LIVE")[9];
    ok($after_end > $after_start, 'mtime bumped on end even with no IPC target');
};

done_testing;
