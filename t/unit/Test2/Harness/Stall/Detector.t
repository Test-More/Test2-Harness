use Test2::V0 -target => 'Test2::Harness::Stall::Detector';
# HARNESS-DURATION-SHORT

use ok $CLASS;

use File::Spec();
use File::Temp qw/tempdir/;
use Test2::Harness::Util::Queue();

my $JOB = 0;

sub new_workdir {
    return tempdir(CLEANUP => 1);
}

sub queue_for {
    my ($dir) = @_;
    return Test2::Harness::Util::Queue->new(file => File::Spec->catfile($dir, 'dispatch.jsonl'));
}

sub record {
    my ($dir, $action, $item, %params) = @_;

    queue_for($dir)->enqueue({
        action => $action,
        item   => $item,
        stamp  => $params{stamp} // time,
        pid    => $params{pid}   // $$,
    });

    return;
}

sub task {
    my (%params) = @_;

    return {
        job_id    => $params{job_id} // 'job-' . ++$JOB,
        run_id    => 'run-1',
        file      => $params{file}     // 'a.t',
        category  => $params{category} // 'general',
        duration  => 'short',
        stage     => 'default',
        conflicts => $params{conflicts} // [],
        shares    => $params{shares}    // [],
        smoke     => 0,
    };
}

# A run with one ready stage and however many queued tasks, laid down far
# enough in the past that any threshold under an hour has elapsed.
sub seed_run {
    my ($dir, %params) = @_;

    my $old = time - 3600;

    record($dir, queue_run   => {run_id => 'run-1'}, stamp => $old);
    record($dir, start_run   => 'run-1',             stamp => $old);
    record($dir, stage_ready => 'default',           stamp => $old);

    for my $t (@{$params{tasks} // []}) {
        record($dir, queue_task => $t, stamp => $old);
    }

    for my $t (@{$params{started} // []}) {
        record($dir, queue_task => $t, stamp => $old);
        record(
            $dir,
            start_task => {
                job_id => $t->{job_id},
                stage  => 'default',
                res    => {args => [], env_vars => {}, record => {}},
            },
            stamp => $params{start_stamp} // $old,
        );
    }

    return;
}

sub detector {
    my ($dir, %params) = @_;

    return $CLASS->new(
        workdir   => $dir,
        job_count => 4,
        strong    => $params{strong} // 600,
        loose     => $params{loose}  // 1200,
    );
}

# These pids feed kill() directly, so a mistake here aims a fatal signal at the
# wrong process. SIGUSR1's default action is to terminate.
subtest pids_for_the_signal_whitelist => sub {
    my $dir = new_workdir();
    my $old = time - 3600;

    record($dir, queue_run   => {run_id => 'run-1'}, stamp => $old, pid => 111);
    record($dir, queue_task  => task(),              stamp => $old, pid => 111);
    record($dir, start_run   => 'run-1',             stamp => $old, pid => 222);
    record($dir, stage_ready => 'default',           stamp => $old, pid => 333);
    record($dir, queue_task  => task(),              stamp => $old, pid => 111);

    my $one = detector($dir);
    $one->check();

    is($one->stage_pids, {default => 333}, "stage pid from stage_ready");

    my $found = detector($dir)->check;
    ok($found, "reported") or return;

    is($found->{scheduler_pid}, 222, "scheduler pid from start_run, not the main process's queue_run");
};

subtest a_stage_that_goes_down_leaves_the_whitelist => sub {
    my $dir = new_workdir();
    my $old = time - 3600;

    record($dir, queue_run   => {run_id => 'run-1'}, stamp => $old);
    record($dir, start_run   => 'run-1',             stamp => $old);
    record($dir, stage_ready => 'default', stamp => $old, pid => 333);
    record($dir, stage_ready => 'other',   stamp => $old, pid => 444);
    record($dir, queue_task  => task(),    stamp => $old);
    record($dir, stage_down  => 'other',   stamp => $old, pid => 444);

    my $detector = detector($dir);
    $detector->check();

    # A dead stage's pid can be recycled, and signalling a process that never
    # installed the handler kills it.
    is($detector->stage_pids, {default => 333}, "the downed stage is gone");
};

subtest a_replay_that_keeps_failing_gives_up => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task()]);

    # start_task for a job that was never queued makes State's handler die.
    record($dir, start_task => {job_id => 'nope', stage => 'default', res => {args => [], env_vars => {}, record => {}}});

    my $detector = detector($dir);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    for (1 .. 6) {
        $detector->{+Test2::Harness::Stall::Detector::LAST_CHECK()} = 0;
        $detector->check();
    }

    # Re-reading a large dispatch file every second for the rest of the run,
    # warning each time, would be worse than not reporting at all.
    ok(@warnings <= 4, "stopped warning") or diag(scalar @warnings);
    like($warnings[-1], qr/disabled/, "said it gave up");
};

subtest parse_spec => sub {
    is([$CLASS->parse_spec('600:1200')], [strong => 600, loose => 1200], "pair");
    is([$CLASS->parse_spec('600')],      [strong => 600, loose => 600],  "single value sets both");
    is([$CLASS->parse_spec('0')],        [], "zero disables");

    # STRONG:0 means "report only when nothing is running" and is enabled.
    # It is also the case a caller loses by testing parse_spec in boolean
    # context, since a list return yields its last value there.
    is([$CLASS->parse_spec('600:0')],  [strong => 600, loose => 0],    "strong only");
    is([$CLASS->parse_spec('0:1200')], [strong => 0,   loose => 1200], "loose only");

    my %strong_only = $CLASS->parse_spec('600:0');
    ok(%strong_only, "strong-only is enabled when the result is used as a list");
    is([$CLASS->parse_spec(undef)], [], "undef disables");
    is([$CLASS->parse_spec('')],    [], "empty disables");
    # An opt-in diagnostic that silently disables itself on a typo is a trap.
    like(dies { $CLASS->parse_spec('abc') },     qr/Invalid --stall-report/, "non-numeric croaks");
    like(dies { $CLASS->parse_spec('600:abc') }, qr/Invalid --stall-report/, "bad second field croaks");
};

subtest the_option_default_is_off_and_bare_means_sensible => sub {
    require App::Yath::Options::Runner;

    my ($opt) = grep { $_->field eq 'stall_report' } @{App::Yath::Options::Runner->options->all};
    ok($opt, "found the option") or return;

    # Given alone the option fills in a usable pair; not given at all it stays
    # off. Both matter: this is opt-in, and nobody should have to know numbers
    # to turn it on.
    is($opt->type,     'd',        "takes an optional value");
    is($opt->autofill, '600:1200', "bare --stall-report means a sensible pair");
    is($opt->default,  0,          "off unless asked for");

    is([$CLASS->parse_spec($opt->autofill)], [strong => 600, loose => 1200], "the autofill parses");
    is([$CLASS->parse_spec($opt->default)],  [],                             "the default is disabled");
};

subtest no_report_before_a_stage_is_ready => sub {
    my $dir = new_workdir();
    my $old = time - 3600;

    # The queue is populated by the main process well before any stage comes
    # up, so during a long preload this looks exactly like a stall.
    record($dir, queue_run  => {run_id => 'run-1'}, stamp => $old);
    record($dir, start_run  => 'run-1',             stamp => $old);
    record($dir, queue_task => task(),              stamp => $old);

    is(detector($dir)->check(), undef, "silent while preloading");
};

subtest strong_tier_when_nothing_is_running => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task(), task()]);

    my $got = detector($dir)->check();
    ok($got, "reported") or return;
    is($got->{tier},    'strong', "strong tier");
    is($got->{running}, 0,        "nothing running");
    is($got->{pending}, 2,        "counted the pending tests");
};

subtest loose_tier_when_something_is_running => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task()], started => [task()]);

    my $got = detector($dir)->check();
    ok($got, "reported") or return;
    is($got->{tier},    'loose', "loose tier");
    is($got->{running}, 1,       "one test running");
};

subtest loose_threshold_is_not_the_strong_one => sub {
    my $dir = new_workdir();

    # 900 seconds idle: past a 600s strong threshold, short of a 1200s loose
    # one. With a test running, only the loose threshold applies.
    seed_run($dir, tasks => [task()], started => [task()], start_stamp => time - 900);

    is(detector($dir)->check(), undef, "waits for the loose threshold");
};

subtest isolation_tail_is_not_a_stall => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task(category => 'isolation')], started => [task()]);

    is(detector($dir)->check(), undef, "isolation cannot start while a test runs");
};

subtest conflict_blocked_is_not_a_stall => sub {
    my $dir     = new_workdir();
    my $running = task(conflicts => ['db']);
    seed_run($dir, tasks => [task(conflicts => ['db'])], started => [$running]);

    is(detector($dir)->check(), undef, "pending test conflicts with a running one");
};

# These mirror the rejections State::_next makes for shared locks. Getting them
# wrong means reporting a stall against a scheduler waiting exactly as it
# should.
subtest an_exclusive_claim_waits_on_a_shared_holder => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task(conflicts => ['db'])], started => [task(shares => ['db'])]);

    is(detector($dir)->check(), undef, "exclusive claim blocked by a running share");
};

subtest a_shared_claim_waits_on_an_exclusive_holder => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task(shares => ['db'])], started => [task(conflicts => ['db'])]);

    is(detector($dir)->check(), undef, "shared claim blocked by a running exclusive");
};

subtest two_shared_claims_do_not_block_each_other => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task(shares => ['db'])], started => [task(shares => ['db'])]);

    ok(detector($dir)->check(), "a share does not block another share, so this is a stall");
};

subtest one_unblocked_pending_test_is_enough => sub {
    my $dir = new_workdir();
    seed_run(
        $dir,
        tasks   => [task(category => 'isolation'), task()],
        started => [task()],
    );

    ok(detector($dir)->check(), "reports when any pending test could have started");
};

subtest nothing_pending_is_not_a_stall => sub {
    my $dir = new_workdir();
    seed_run($dir, started => [task()]);

    is(detector($dir)->check(), undef, "no pending tests, nothing to report");
};

subtest disabled_by_zero => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task()]);

    is(detector($dir, strong => 0, loose => 0)->check(), undef, "no report when disabled");
};

subtest repeat_is_rate_limited_and_capped => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task()]);

    my $one = detector($dir);
    ok($one->check(), "first report");
    $one->{+Test2::Harness::Stall::Detector::LAST_CHECK()} = 0;
    is($one->check(), undef, "second report held back");

    my $two = detector($dir);
    $two->{+Test2::Harness::Stall::Detector::REPORTS()} = [map { time - 10_000 } 1 .. 5];
    is($two->check(), undef, "stops after the cap");
};

subtest a_torn_trailing_line_is_ignored => sub {
    my $dir = new_workdir();
    seed_run($dir, tasks => [task()]);

    open(my $fh, '>>', File::Spec->catfile($dir, 'dispatch.jsonl')) or die "Could not open queue: $!";
    print $fh '{"action":"queue_task","item":';    # no newline
    close($fh);

    ok(detector($dir)->check(), "still reported despite the partial record");
};

done_testing;
