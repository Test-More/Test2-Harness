use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Harness2::Collector;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

# Integration test for the harness-level finalization sweep (_finalize_sweep).
#
# Strategy: build a synthetic logdir fixture (no real harness fork), instantiate
# a top-level harness collector pointing at that logdir, call _finalize_sweep
# directly, then assert .sealed file presence and content.
#
# No App::Yath2 modules are loaded -- the sweep walks dirs with readdir only.

# ─── helpers ─────────────────────────────────────────────────────────────────

sub read_sealed {
    my ($logdir, $rel) = @_;
    my $path = "$logdir/$rel/.sealed";
    return undef unless -e $path;
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    chomp $raw;
    return decode_json($raw);
}

# Write a pre-existing .sealed file so we can test the existing-file-wins rule.
sub write_sealed {
    my ($logdir, $rel, %fields) = @_;
    my $dir  = "$logdir/$rel";
    my $path = "$dir/.sealed";
    open my $fh, '>', $path or die "Could not write $path: $!";
    print $fh encode_json({sealed_at => 1000, %fields}), "\n";
    close $fh;
}

# Build the top-level harness collector (no ipc_parent, no ipc_run).
sub make_top_level_collector {
    my ($logdir) = @_;
    return Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'self',
        type        => 'Run',
        id          => 1,
        run_id      => 1,
        logdir      => $logdir,
        launch      => ['perl', '-e', '1'],
        # ipc_parent and ipc_run intentionally absent → _is_top_level_harness returns 1
    );
}

# Build a non-top-level (child run) collector.
sub make_child_collector {
    my ($logdir) = @_;
    return Test2::Harness2::Collector->new(
        ipcm_info   => {},
        ipc_harness => 'harness',
        ipc_parent  => 'harness',
        type        => 'Run',
        id          => 2,
        run_id      => 2,
        logdir      => $logdir,
        launch      => ['perl', '-e', '1'],
    );
}

# ─── subtest: all sealed already ─────────────────────────────────────────────

subtest 'all sealed already: sweep does not clobber existing markers' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Build fixture: runs/1 and runs/1/jobs/1/0 both already sealed.
    for my $path (
        "$dir/runs",
        "$dir/runs/1",
        "$dir/runs/1/jobs",
        "$dir/runs/1/jobs/1",
        "$dir/runs/1/jobs/1/0",
        )
    {
        mkdir $path, 0755 or die "mkdir $path: $!" unless -d $path;
    }
    write_sealed($dir, 'runs/1',          final_state => 'completed');
    write_sealed($dir, 'runs/1/jobs/1/0', final_state => 'completed');

    my $run_ts = read_sealed($dir, 'runs/1')->{sealed_at};
    my $job_ts = read_sealed($dir, 'runs/1/jobs/1/0')->{sealed_at};

    my $c = make_top_level_collector($dir);
    $c->_finalize_sweep;

    my $run_after = read_sealed($dir, 'runs/1');
    my $job_after = read_sealed($dir, 'runs/1/jobs/1/0');

    ok(defined $run_after, 'runs/1/.sealed still present');
    ok(defined $job_after, 'runs/1/jobs/1/0/.sealed still present');

    is($run_after->{sealed_at},   $run_ts,     'runs/1 sealed_at unchanged (existing-file-wins)');
    is($job_after->{sealed_at},   $job_ts,     'job sealed_at unchanged (existing-file-wins)');
    is($run_after->{final_state}, 'completed', 'runs/1 final_state still completed');
    is($job_after->{final_state}, 'completed', 'job final_state still completed');
};

# ─── subtest: partial sweep ───────────────────────────────────────────────────

subtest 'partial sweep: writes abandoned for missing .sealed, preserves existing' => sub {
    my $dir = tempdir(CLEANUP => 1);

    for my $path (
        "$dir/runs",
        "$dir/runs/1",
        "$dir/runs/1/jobs",
        "$dir/runs/1/jobs/1",
        "$dir/runs/1/jobs/1/0",
        )
    {
        mkdir $path, 0755 or die "mkdir $path: $!" unless -d $path;
    }

    # Job already sealed; run is NOT sealed.
    write_sealed($dir, 'runs/1/jobs/1/0', final_state => 'completed', exit => 0);

    my $job_ts = read_sealed($dir, 'runs/1/jobs/1/0')->{sealed_at};

    my $c = make_top_level_collector($dir);
    $c->_finalize_sweep;

    my $run_data = read_sealed($dir, 'runs/1');
    my $job_data = read_sealed($dir, 'runs/1/jobs/1/0');

    ok(defined $run_data, 'runs/1/.sealed now exists after sweep');
    is($run_data->{final_state}, 'abandoned', 'runs/1 written with final_state=abandoned');
    ok($run_data->{sealed_at} > 0, 'runs/1 has a positive sealed_at timestamp');

    ok(defined $job_data, 'runs/1/jobs/1/0/.sealed still present');
    is($job_data->{sealed_at},   $job_ts,     'job sealed_at unchanged (first-write-wins)');
    is($job_data->{final_state}, 'completed', 'job final_state still completed');
};

# ─── subtest: full crash sweep ────────────────────────────────────────────────

subtest 'full crash sweep: no .sealed anywhere — all get abandoned' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Build a fixture with no .sealed files anywhere.
    for my $path (
        "$dir/runs",
        "$dir/runs/1",
        "$dir/runs/1/jobs",
        "$dir/runs/1/jobs/1",
        "$dir/runs/1/jobs/1/0",
        "$dir/runs/1/services",
        "$dir/runs/1/services/preload",
        "$dir/services",
        "$dir/services/globalsvc",
        "$dir/collectors",
        "$dir/collectors/c1",
        )
    {
        mkdir $path, 0755 or die "mkdir $path: $!" unless -d $path;
    }

    my $c = make_top_level_collector($dir);
    $c->_finalize_sweep;

    my @expected = (
        ['runs/1',                  'run-level producer'],
        ['runs/1/jobs/1/0',         'job try'],
        ['runs/1/services/preload', 'run-scoped service'],
        ['services/globalsvc',      'global service'],
        ['collectors/c1',           'collector'],
    );

    for my $pair (@expected) {
        my ($rel, $label) = @$pair;
        my $data = read_sealed($dir, $rel);
        ok(defined $data, "$label: .sealed written");
        is($data->{final_state}, 'abandoned', "$label: final_state=abandoned");
        ok($data->{sealed_at} > 0, "$label: sealed_at is positive");
    }
};

# ─── subtest: non-top-level no-op ────────────────────────────────────────────

subtest 'non-top-level collector: _finalize_sweep is a no-op' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Create the runs/2 dir without a .sealed file.
    mkdir "$dir/runs",   0755;
    mkdir "$dir/runs/2", 0755;

    my $c = make_child_collector($dir);
    $c->_finalize_sweep;

    # Nothing should have been written.
    ok(!-e "$dir/runs/2/.sealed", 'non-top-level sweep wrote nothing');
};

done_testing;
