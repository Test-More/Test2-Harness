use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/write_json_file_atomic decode_json/;

use App::Yath2::Command::speedtag;

# Build a synthetic log directory carrying two completed jobs whose
# wall-clock durations are computed from started_at / completed_at on
# the state snapshot. Two real test files live inside the temp dir so
# the command can rewrite their HARNESS-DURATION-* headers.

sub build_fixture {
    my (%opts) = @_;

    my $tmp     = tempdir(CLEANUP => 1);
    my $logdir  = "$tmp/logs";
    my $testdir = "$tmp/t";
    make_path("$logdir/runs/R/tests", "$logdir/runs/R/tests/J1", "$logdir/runs/R/tests/J2", "$logdir/runs/R/tests/J3");
    make_path($testdir);

    my $short_file  = "$testdir/short.t";
    my $medium_file = "$testdir/medium.t";
    my $long_file   = "$testdir/long.t";

    for my $path ($short_file, $medium_file, $long_file) {
        open my $fh, '>', $path or die "open $path: $!";
        print $fh "use strict;\nuse warnings;\nprint \"ok\\n\";\n";
        close $fh;
    }

    # Phase 4: every runs/<id>/ must carry spec.json. The static
    # streamer's archive iterator picks up *.json by extension so both
    # spec.json and state.json are read as state snapshots; give them
    # identical content so the agreement check passes regardless of
    # iteration order.
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
                    completed_at => 102,           # 2s -> short
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/short.t',
                    abs_file     => $short_file,
                    file         => $short_file,
                },
                J2 => {
                    job_id       => 'J2',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 100,
                    completed_at => 120,            # 20s -> medium
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/medium.t',
                    abs_file     => $medium_file,
                    file         => $medium_file,
                },
                J3 => {
                    job_id       => 'J3',
                    job_try      => 0,
                    queued_at    => 1,
                    started_at   => 100,
                    completed_at => 200,            # 100s -> long
                    pass         => 1,
                    exit         => 0,
                    rel_file     => 't/long.t',
                    abs_file     => $long_file,
                    file         => $long_file,
                },
            },
    };
    write_json_file_atomic("$logdir/runs/R/spec.json",  $state);
    write_json_file_atomic("$logdir/runs/R/state.json", $state);

    # Empty event JSONLs are fine; speedtag only looks at lifecycle.
    open my $j1, '>', "$logdir/runs/R/tests/J1/0.jsonl" or die $!;
    close $j1;
    open my $j2, '>', "$logdir/runs/R/tests/J2/0.jsonl" or die $!;
    close $j2;
    open my $j3, '>', "$logdir/runs/R/tests/J3/0.jsonl" or die $!;
    close $j3;

    return ($logdir, $short_file, $medium_file, $long_file, $tmp);
}

sub make_cmd {
    my (%opts) = @_;
    my $sp = mock {} => (
        add => [
            generate_durations_file => sub { $opts{durations_file} },
            pretty                  => sub { 0 },
        ]
    );
    my $hs = mock {} => (add => [dummy => sub { $opts{dummy} ? 1 : 0 }]);
    my $s  = mock {} => (
        add => [
            speedtag => sub { $sp },
            harness  => sub { $hs },
        ]
    );
    return App::Yath2::Command::speedtag->new(
        settings => $s,
        args     => $opts{args},
        plugins  => [],
    );
}

# ----------------------------------------------------------------------
subtest 'dummy mode reports tags without modifying files' => sub {
    my ($logdir, $short, $medium, $long) = build_fixture();

    my $cmd = make_cmd(
        args  => [$logdir, '5', '30'],
        dummy => 1,
    );

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    like($out, qr/Would tag.*short\.t.*duration 'short'/s,   'short flagged short');
    like($out, qr/Would tag.*medium\.t.*duration 'medium'/s, 'medium flagged medium');
    like($out, qr/Would tag.*long\.t.*duration 'long'/s,     'long flagged long');

    for my $f ($short, $medium, $long) {
        open my $fh, '<', $f or die $!;
        my $body = do { local $/; <$fh> };
        close $fh;
        unlike($body, qr/HARNESS-DURATION/, "no header written to $f in dummy mode");
    }
};

# ----------------------------------------------------------------------
subtest 'live mode rewrites the test file headers' => sub {
    my ($logdir, $short, $medium, $long) = build_fixture();

    my $cmd = make_cmd(args => [$logdir, '5', '30']);

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    my %expect = (
        $short  => 'SHORT',
        $medium => 'MEDIUM',
        $long   => 'LONG',
    );
    while (my ($f, $want) = each %expect) {
        open my $fh, '<', $f or die $!;
        my $body = do { local $/; <$fh> };
        close $fh;
        like($body, qr/^#\s*HARNESS-DURATION-$want/m, "$f tagged with $want");
    }
};

# ----------------------------------------------------------------------
subtest 'durations file gets written when requested' => sub {
    my ($logdir, $short, $medium, $long, $tmp) = build_fixture();

    my $dfile = "$tmp/durations.json";
    my $cmd   = make_cmd(
        args           => [$logdir, '5', '30'],
        durations_file => $dfile,
    );

    my $out = '';
    {
        open my $fh, '>', \$out or die $!;
        local *STDOUT = $fh;
        is($cmd->run, 0, 'run() returned 0');
    }

    ok(-f $dfile, 'durations file exists');

    open my $fh, '<', $dfile or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    my $data = decode_json($body);
    is(ref($data), 'HASH', 'durations file is a JSON object');

    my $values = join ',' => sort values %$data;
    is($values, 'LONG,MEDIUM,SHORT', 'all three durations recorded');
};

# ----------------------------------------------------------------------
subtest 'invalid threshold dies with a helpful error' => sub {
    my ($logdir) = build_fixture();
    my $cmd = make_cmd(args => [$logdir, 'oops', '30'], dummy => 1);
    like(
        dies { $cmd->run }, qr/max short duration must be an integer/,
        'non-integer short threshold rejected'
    );
};

done_testing;
