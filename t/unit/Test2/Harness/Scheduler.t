use Test2::V0 -target => 'Test2::Harness::Scheduler';

use File::Temp qw/tempdir/;
use Test2::Harness::Runner;
use Test2::Harness::TestSettings;

my $dir = tempdir(CLEANUP => 1);

sub make_scheduler {
    my %params = @_;

    my $runner = Test2::Harness::Runner->new(
        workdir       => $dir,
        test_settings => Test2::Harness::TestSettings->new(),
    );

    return $CLASS->new(runner => $runner, %params);
}

subtest 'abort terminates the scheduler' => sub {
    my $sched = make_scheduler();

    ok(!$sched->terminated, "scheduler is not terminated initially");

    $sched->abort();

    ok($sched->terminated, "scheduler is terminated after abort()");
    is($sched->terminated, 1, "terminate reason is 1");
};

subtest 'abort with no running jobs still terminates' => sub {
    my $sched = make_scheduler();

    ok(!$sched->terminated, "scheduler is not terminated initially");
    is($sched->{running}{jobs}, undef, "no running jobs");

    $sched->abort();

    ok($sched->terminated, "scheduler terminates even with no running jobs");
};

subtest 'kill delegates to abort and terminates' => sub {
    my $sched = make_scheduler();

    ok(!$sched->terminated, "scheduler is not terminated initially");

    $sched->kill();

    ok($sched->terminated, "scheduler is terminated after kill()");
};

subtest 'terminate is idempotent' => sub {
    my $sched = make_scheduler();

    my $reason1 = $sched->terminate('first');
    is($reason1, 'first', "first terminate returns the reason");

    my $reason2 = $sched->terminate('second');
    is($reason2, 'first', "second terminate returns original reason");
};

subtest 'abort marks runs as halted' => sub {
    my $sched = make_scheduler();

    # Create a mock run object
    my $halt_value;
    my $mock_run = mock {} => (
        add => [
            set_halt => sub { $halt_value = $_[1] },
            run_id   => sub { 'run-1' },
        ],
    );

    $sched->{runs}{'run-1'} = $mock_run;

    $sched->abort();

    is($halt_value, 'aborted', "run was marked as halted/aborted");
    ok($sched->terminated, "scheduler terminated after abort");
};

subtest 'abort kills running job PIDs' => sub {
    my $sched = make_scheduler();

    my $halt_value;
    my $mock_run = mock {} => (
        add => [
            set_halt => sub { $halt_value = $_[1] },
            run_id   => sub { 'run-1' },
        ],
    );

    $sched->{runs}{'run-1'} = $mock_run;

    # Use a child process so TERM doesn't kill us
    my $child = fork();
    if (!defined $child) {
        skip_all "fork failed: $!";
    }
    elsif ($child == 0) {
        sleep 10;
        exit 0;
    }

    $sched->{running}{jobs}{'job-1'} = {
        run    => $mock_run,
        pid    => $child,
        killed => 0,
    };

    $sched->abort();

    ok($sched->{running}{jobs}{'job-1'}{killed}, "job was marked as killed");
    ok($sched->terminated, "scheduler terminated after abort with running jobs");

    # Clean up child
    kill('KILL', $child);
    waitpid($child, 0);
};

subtest 'abort with specific run IDs only aborts those runs' => sub {
    my $sched = make_scheduler();

    my %halt_values;
    for my $id ('run-1', 'run-2') {
        my $run_id = $id;
        $sched->{runs}{$id} = mock {} => (
            add => [
                set_halt => sub { $halt_values{$run_id} = $_[1] },
                run_id   => sub { $run_id },
            ],
        );
    }

    $sched->abort('run-1');

    is($halt_values{'run-1'}, 'aborted', "run-1 was aborted");
    ok(!exists $halt_values{'run-2'}, "run-2 was not aborted");
    ok($sched->terminated, "scheduler still terminates");
};

done_testing;
