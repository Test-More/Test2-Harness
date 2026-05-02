use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use App::Yath2::Command::times;

# Build a synthetic log directory carrying three completed jobs with
# distinct wall-clock durations. The command derives totals from
# started_at / completed_at on the state snapshot and renders a sorted
# table.

sub build_logs {
    my $tmp    = tempdir(CLEANUP => 1);
    my $logdir = "$tmp/logs";
    make_path("$logdir/runs/R/tests", "$logdir/runs/R/tests/J1", "$logdir/runs/R/tests/J2", "$logdir/runs/R/tests/J3");

    # Phase 4: every runs/<id>/ must carry spec.json. The static
    # streamer reads every *.json under runs/<id>/ as a state snapshot
    # (loggers are resolved by extension), so spec.json and state.json
    # must agree -- mirror the same content into both.
    my $state = {
            run_id     => 'R',
            created_at => 1,
            pending    => [],
            running    => [],
            done       => ['J1', 'J2', 'J3'],
            results    => {
                J1 => {
                    job_id       => 'J1',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 100,
                    completed_at => 101,
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/quick.t',
                    abs_file     => '/abs/quick.t',
                    file         => '/abs/quick.t',
                },
                J2 => {
                    job_id       => 'J2',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 100,
                    completed_at => 105,
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/middle.t',
                    abs_file     => '/abs/middle.t',
                    file         => '/abs/middle.t',
                },
                J3 => {
                    job_id       => 'J3',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 100,
                    completed_at => 110,
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/slow.t',
                    abs_file     => '/abs/slow.t',
                    file         => '/abs/slow.t',
                },
            },
    };
    write_json_file_atomic("$logdir/runs/R/spec.json",  $state);
    write_json_file_atomic("$logdir/runs/R/state.json", $state);

    open my $j1, '>', "$logdir/runs/R/tests/J1/0.jsonl" or die $!;
    close $j1;
    open my $j2, '>', "$logdir/runs/R/tests/J2/0.jsonl" or die $!;
    close $j2;
    open my $j3, '>', "$logdir/runs/R/tests/J3/0.jsonl" or die $!;
    close $j3;

    return $logdir;
}

sub make_cmd {
    my (%opts) = @_;
    my $hs     = mock {} => (add => [dummy   => sub { 0 }]);
    my $s      = mock {} => (add => [harness => sub { $hs }]);
    return App::Yath2::Command::times->new(
        settings => $s,
        args     => $opts{args},
        plugins  => [],
    );
}

# ----------------------------------------------------------------------
subtest 'default sort is shortest -> longest' => sub {
    my $log = build_logs();
    my $cmd = make_cmd(args => [$log]);

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    my @order;
    for my $line (split /\n/, $out) {
        next unless $line =~ m{(t/[a-z]+\.t)};
        push @order => $1;
    }

    is(
        \@order, ['t/quick.t', 't/middle.t', 't/slow.t'],
        'rows sorted by total ascending'
    );
    like($out, qr/TOTAL/, 'TOTAL row present');
};

# ----------------------------------------------------------------------
subtest 'file sort overrides the default' => sub {
    my $log = build_logs();
    my $cmd = make_cmd(args => [$log, 'file']);

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    my @order;
    for my $line (split /\n/, $out) {
        next unless $line =~ m{(t/[a-z]+\.t)};
        push @order => $1;
    }

    is(
        \@order, ['t/middle.t', 't/quick.t', 't/slow.t'],
        'rows sorted alphabetically when file is the leading field'
    );
};

# ----------------------------------------------------------------------
subtest 'unknown field is rejected' => sub {
    my $log = build_logs();
    my $cmd = make_cmd(args => [$log, 'startup']);
    like(
        dies { $cmd->run }, qr/'startup' is not a valid field/,
        'legacy startup field rejected since it has no source in the new stream'
    );
};

# ----------------------------------------------------------------------
subtest 'missing log path dies cleanly' => sub {
    my $cmd = make_cmd(args => ['/no/such/log/here']);
    like(
        dies { $cmd->run }, qr/does not exist/,
        'missing log dies with helpful error'
    );
};

done_testing;
