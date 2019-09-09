use Test2::V0 -target => 'Test2::Harness::Run::Runner::ProcMan';
use v5.10;
# HARNESS-DURATION-SHORT

use Test2::Util qw/CAN_REALLY_FORK/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;

use File::Temp qw/tempdir/;
my $dir = tempdir(CLEANUP => 1);

my %sigs = map {state $num = 0; ($_ => $num++)} split(/\s+/, $Config{sig_name});

subtest init => sub {
    like(dies { $CLASS->new() }, qr/'run' is a required attribute/, "Need a run");
    like(dies { $CLASS->new(run => 1) }, qr/'dir' is a required attribute/, "Need a dir");
    like(dies { $CLASS->new(run => 1, dir => $dir) }, qr/'queue' is a required attribute/, "Need a queue");
    like(dies { $CLASS->new(run => 1, dir => $dir, queue => 1) }, qr/'jobs_file' is a required attribute/, "Need a jobs_file");
    like(dies { $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1) }, qr/'stages' is a required attribute/, "Need a 'stages'");

    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => 1);
    is($one->pid, $$, "set pid");
    is($one->wait_time, 0.02, "set wait time");
    isa_ok($one->jobs, ['Test2::Harness::Util::File::JSONL'], "Opened jobs file");
};

subtest poll_tasks => sub {
    my $queue = Test2::Harness::Run::Queue->new(file => "$dir/queue_a.jsonl");
    my $one = $CLASS->new(run => 1, dir => $dir, queue => $queue, jobs_file => "$dir/jobs_a.jsonl", stages => {default => 1, other => 1});

    is($one->poll_tasks,  0,     "Nothing added");
    is($one->queue_ended, undef, "Queue has not ended");
    is($one->pending,     undef, "Nothing pending");

    $queue->enqueue({test => 1});
    $queue->enqueue({test => 2});
    is($one->poll_tasks,  2,     "2 added");
    is($one->queue_ended, undef, "Queue has not ended");
    is(
        $one->pending,
        {
            default => [
                {
                    category => 'general',
                    duration => 'medium',
                    stage    => 'default',
                    stamp    => T(),
                    test     => 1,
                },
                {
                    category => 'general',
                    duration => 'medium',
                    stage    => 'default',
                    stamp    => T(),
                    test     => 2,
                }
            ],
        },
        "2 pending under default, set category, duration, and stage to defaults"
    );

    $queue->enqueue({test => 3, category => 'isolation', duration => 'long', stage => 'other'});
    $queue->enqueue({test => 4, category => 'fake',      duration => 'fake', stage => 'fake'});
    $queue->end();
    is($one->poll_tasks,  3,   "3 added, counting terminator");
    is($one->queue_ended, T(), "Queue ended");
    is(
        $one->pending,
        {
            default => [
                {
                    category => 'general',
                    duration => 'medium',
                    stage    => 'default',
                    stamp    => T(),
                    test     => 1,
                },
                {
                    category => 'general',
                    duration => 'medium',
                    stage    => 'default',
                    stamp    => T(),
                    test     => 2,
                },
                {
                    category => 'general',
                    duration => 'medium',
                    stage    => 'default',
                    stamp    => T(),
                    test     => 4,
                },

            ],
            other => [
                {
                    category => 'isolation',
                    duration => 'long',
                    stage    => 'other',
                    stamp    => T(),
                    test     => 3,
                },
            ],

        },
        "honor non-defaults, but fix invalid ones"
    );
};

subtest job_started => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => "$dir/jobs_b.jsonl", stages => {});

    require Test2::Harness::Job;
    my $job = Test2::Harness::Job->new(file => 'fake', job_id => 123);

    $one->{_state_cache} = 1;
    $one->job_started(pid => 123, job => $job);
    ok(!$one->{_state_cache}, "state cache was cleared");

    my ($line) = $one->jobs->read();
    like(
        $line,
        {
            use_timeout => 1,
            use_stream  => 1,
            use_fork    => 1,
            job_name    => 123,
            job_id      => 123,
            pid         => 123,
            input       => '',
            file        => 'fake',
            abs_file    => qr/fake$/,
            rel_file    => qr/fake$/,
            libs        => [],
            args        => [],
            switches    => [],
            env_vars    => {},
        },
        "Read file"
    );

    is(
        $one->_pids,
        {123 => {pid => 123, job => exact_ref($job)}},
        "Added pid and job to the pid list"
    );
};

subtest kill => sub {
    skip_all "Need forking" unless CAN_REALLY_FORK();
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = {};

    my @pids;
    for (1 .. 3) {
        my $pid = fork();
        die "Could not fork" unless defined $pid;
        if ($pid) {
            push @pids => $pid;
            $one->_pids->{$pid} = {pid => $pid, job => {}};
            next;
        }
        eval { sleep 1 while 1 };
        exit 0;
    }

    $one->kill();

    for my $pid (@pids) {
        my $check = waitpid($pid, 0);
        my $exit  = $?;

        is($pid, $check, "process $pid terminated");
        is($exit, $sigs{TERM}, "Killed with TERM signal");
    }
};

subtest finish => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = {
        1 => {},
        2 => {},
        3 => {},
    };

    my $run_count = 1;
    my $control = mock $CLASS => (
        override => [
            wait_on_jobs => sub {
                delete $one->{_pids}->{$run_count++};
            }
        ],
    );

    $one->finish();
    is($run_count, 4, "Ran 3 times");
    is($one->{_pids}, {}, "Cleared all processes");
};

subtest wait_on_jobs => sub {
    skip_all "Need forking" unless CAN_REALLY_FORK();
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = {};

    my @pids;
    for my $i (1 .. 3) {
        my $pid = fork();
        die "Could not fork" unless defined $pid;
        if ($pid) {
            push @pids => $pid;
            mkdir "$dir/$pid" or die "$!";
            $one->_pids->{$pid} = {pid => $pid, dir => "$dir/$pid"};
            next;
        }
        exit 0;
    }

    $one->{_state_cache} = 1;
    $one->wait_on_jobs() while keys %{$one->{_pids}};
    ok(!$one->{_state_cache}, "state cache was cleared");

    for my $pid (@pids) {
        open(my $fh, '<', "$dir/$pid/exit") or fail("Could not open exit file: $!");
        my $line = <$fh>;
        my ($exit, $stamp) = split /\s+/, $line, 2;
        is($exit, 0, "Exited normally");
        is($stamp, T(), "got a time stamp");
    }
};

subtest write_remaining_exits => sub {
    skip_all "Need forking" unless CAN_REALLY_FORK();
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = {};

    my @pids;
    for my $i (1 .. 3) {
        my $pid = fork();
        die "Could not fork" unless defined $pid;
        if ($pid) {
            push @pids => $pid;
            mkdir "$dir/$pid" or die "$!";
            $one->_pids->{$pid} = {pid => $pid, dir => "$dir/$pid"};
            next;
        }
        eval { sleep 1 while 1 };
        exit 0;
    }

    $one->write_remaining_exits();

    for my $pid (@pids) {
        open(my $fh, '<', "$dir/$pid/exit") or fail("Could not open exit file: $!");
        my $line = <$fh>;
        my ($exit, $stamp) = split /\s+/, $line, 2;
        is($exit, -1, "Never exited");
        is($stamp, T(), "got a time stamp");
        kill('TERM', $pid);
        die "Failed to kill pid $pid" unless waitpid($pid, 0) == $pid;
    }
};

subtest write_exit => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});
    $one->write_exit(dir => $dir, exit => 500, stamp => 600);
    open(my $fh, '<', "$dir/exit") or fail("Could not open exit file: $!");
    my $line = <$fh>;
    my ($exit, $stamp) = split /\s+/, $line, 2;
    is($exit, 500, "Got the exit value");
    is($stamp, 600, "Got the stamp value");
};

subtest next => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = { 1 => {} };
    my @next = ( 'a', 'b', 'c' );
    my $wait;

    my $control = mock $CLASS => (
        override => [
            _next => sub { shift @next },
            wait_on_jobs => sub { $one->{_pids} = {} if ++$wait == 3 },
        ],
    );

    is($one->next, 'a', "First task");
    ok(!$wait, "Did not wait yet");

    is($one->next, 'b', "Second task");
    ok(!$wait, "Did not wait yet");

    is($one->next, 'c', "Third task");
    ok(!$wait, "Did not wait yet");

    is($one->next, undef, "No more tasks");
    is($wait, 3, "Waited as needed");
};

subtest locking => sub {
    my $lockfile = "$dir/lock";
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {}, lock_file => $lockfile);

    open(my $lock, '>>', $lockfile) or die "Could not open lock file: $!";
    flock($lock, LOCK_EX | LOCK_NB) or die "Could not lock!";

    ok(!$one->lock, "Could not lock file, already locked");

    flock($lock, LOCK_UN | LOCK_NB) or die "Could not unlock";

    ok($one->lock, "Got lock");
    ok(!flock($lock, LOCK_EX | LOCK_NB), "File is locked");
    ok($one->lock, "Still locked");

    $one->unlock();
    ok(flock($lock, LOCK_EX | LOCK_NB), "File was unlocked");

    $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});
    ok($one->lock, "Lock always returns true with no lock file");
    ok($one->lock, "Lock always returns true with no lock file");
    ok($one->unlock, "Unlock always returns true with no lock file");
};

subtest running_state => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{_pids} = {
        1 => {task => {category => 'general', duration => 'medium', conflicts => []}},
        2 => {task => {category => 'general', duration => 'medium', conflicts => []}},
        3 => {task => {category => 'immiscible', duration => 'short', conflicts => []}},
        4 => {task => {category => 'isolation', duration => 'long', conflicts => []}},
        5 => {task => {category => 'general', duration => 'medium', conflicts => ['foo']}},
        6 => {task => {category => 'general', duration => 'medium', conflicts => ['bar']}},
    };

    is(
        $one->_running_state,
        {
            running    => 6,
            categories => {general => 4, immiscible => 1, isolation => 1},
            durations  => {medium => 4, short => 1, long => 1},
            conflicts  => {foo => 1, bar => 1},
        },
        "Got running state"
    );

    my $it = $one->_running_state;
    ref_is($it, $one->_running_state, "Cached results");
    delete $one->{_state_cache};
    ref_is_not($it, $one->_running_state, "Cache was cleared");
};

subtest next_simple => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    ok(!$one->_next_simple('default'), "Nothing to do");

    push @{$one->pending->{default}} => {foo => 'bar'};

    is(
        $one->_next_simple('default'),
        {foo => 'bar'},
        "Got next"
    );
};

subtest group_items => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{pending}->{default} = [
        {job_id => 1, category => 'general', duration => 'short'},
        {job_id => 2, category => 'general', duration => 'medium'},
        {job_id => 3, category => 'general', duration => 'long'},
        {job_id => 4, category => 'general', duration => 'short'},
        {job_id => 5, category => 'general', duration => 'medium'},
        {job_id => 6, category => 'general', duration => 'long'},

        {job_id => 7,  category => 'immiscible', duration => 'short'},
        {job_id => 8,  category => 'immiscible', duration => 'medium'},
        {job_id => 9,  category => 'immiscible', duration => 'long'},
        {job_id => 10, category => 'immiscible', duration => 'short'},
        {job_id => 11, category => 'immiscible', duration => 'medium'},
        {job_id => 12, category => 'immiscible', duration => 'long'},

        {job_id => 13, category => 'isolation', duration => 'short'},
        {job_id => 14, category => 'isolation', duration => 'medium'},
        {job_id => 15, category => 'isolation', duration => 'long'},
        {job_id => 16, category => 'isolation', duration => 'short'},
        {job_id => 17, category => 'isolation', duration => 'medium'},
        {job_id => 18, category => 'isolation', duration => 'long'},
    ];

    my $grouped = $one->_group_items('default');
    is(${$one->{todo}->{default}}, 18, "18 items todo in the grouped structure");
    is(
        $grouped,
        {
            general => {
                short => [
                    {job_id => 1, category => 'general', duration => 'short'},
                    {job_id => 4, category => 'general', duration => 'short'},
                ],
                medium => [
                    {job_id => 2, category => 'general', duration => 'medium'},
                    {job_id => 5, category => 'general', duration => 'medium'},
                ],
                long => [
                    {job_id => 3, category => 'general', duration => 'long'},
                    {job_id => 6, category => 'general', duration => 'long'},
                ],
            },
            immiscible => {
                short => [
                    {job_id => 7,  category => 'immiscible', duration => 'short'},
                    {job_id => 10, category => 'immiscible', duration => 'short'},
                ],
                medium => [
                    {job_id => 8,  category => 'immiscible', duration => 'medium'},
                    {job_id => 11, category => 'immiscible', duration => 'medium'},
                ],
                long => [
                    {job_id => 9,  category => 'immiscible', duration => 'long'},
                    {job_id => 12, category => 'immiscible', duration => 'long'},
                ],
            },
            isolation => {
                short => [
                    {job_id => 13, category => 'isolation', duration => 'short'},
                    {job_id => 16, category => 'isolation', duration => 'short'},
                ],
                medium => [
                    {job_id => 14, category => 'isolation', duration => 'medium'},
                    {job_id => 17, category => 'isolation', duration => 'medium'},
                ],
                long => [
                    {job_id => 15, category => 'isolation', duration => 'long'},
                    {job_id => 18, category => 'isolation', duration => 'long'},
                ],
            },
        },
        "Grouped the items"
    );

    push @{$one->{pending}->{default}} => (
        {job_id => 19, category => 'general',    duration => 'short'},
        {job_id => 20, category => 'immiscible', duration => 'short'},
    );

    $grouped = $one->_group_items('default');
    is(${$one->{todo}->{default}}, 20, "20 items todo in the grouped structure");
    is(
        $grouped,
        {
            general => {
                short => [
                    {job_id => 1,  category => 'general', duration => 'short'},
                    {job_id => 4,  category => 'general', duration => 'short'},
                    {job_id => 19, category => 'general', duration => 'short'},
                ],
                medium => [
                    {job_id => 2, category => 'general', duration => 'medium'},
                    {job_id => 5, category => 'general', duration => 'medium'},
                ],
                long => [
                    {job_id => 3, category => 'general', duration => 'long'},
                    {job_id => 6, category => 'general', duration => 'long'},
                ],
            },
            immiscible => {
                short => [
                    {job_id => 7,  category => 'immiscible', duration => 'short'},
                    {job_id => 10, category => 'immiscible', duration => 'short'},
                    {job_id => 20, category => 'immiscible', duration => 'short'},
                ],
                medium => [
                    {job_id => 8,  category => 'immiscible', duration => 'medium'},
                    {job_id => 11, category => 'immiscible', duration => 'medium'},
                ],
                long => [
                    {job_id => 9,  category => 'immiscible', duration => 'long'},
                    {job_id => 12, category => 'immiscible', duration => 'long'},
                ],
            },
            isolation => {
                short => [
                    {job_id => 13, category => 'isolation', duration => 'short'},
                    {job_id => 16, category => 'isolation', duration => 'short'},
                ],
                medium => [
                    {job_id => 14, category => 'isolation', duration => 'medium'},
                    {job_id => 17, category => 'isolation', duration => 'medium'},
                ],
                long => [
                    {job_id => 15, category => 'isolation', duration => 'long'},
                    {job_id => 18, category => 'isolation', duration => 'long'},
                ],
            },
        },
        "Added to the grouped the items"
    );
};

subtest cat_order => sub {
    my $state = {running => 0, categories => {general => 0, immiscible => 0, isolation => 0}};
    my $control = mock $CLASS => (override => [_running_state => sub { $state }]);

    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    is($one->_cat_order, [qw/immiscible general isolation/], "Anything goes, immiscible first, isolation last");

    $state->{running} = 1;
    is($one->_cat_order, [qw/immiscible general/], "No isolation if anything is running");

    $state->{categories}->{immiscible} = 1;
    is($one->_cat_order, [qw/general/], "No immiscible if anything immiscible is running");
};

subtest dur_order => sub {
    my $state = {durations => {short => 0, medium => 0, long => 0}};
    my $control = mock $CLASS => (override => [_running_state => sub { $state }]);

    my $count = 0;
    my $run = mock {} => (add => [ job_count => sub { $count }]);
    my $one = $CLASS->new(run => $run, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $count = 5;
    is($one->_dur_order, [qw/long medium short/], "Multiple processes with nothing running means longest first");

    $state->{durations}->{long} = 4;
    is($one->_dur_order, [qw/medium short long/], "Do not max out procs with long");

    $state->{durations}->{medium} = 4;
    is($one->_dur_order, [qw/short medium long/], "Do not max out procs with medium");

    $state->{durations}->{long} = 3;
    is($one->_dur_order, [qw/long short medium/], "max long is n-1");

    $state->{durations}->{long} = 3;
    $state->{durations}->{medium} = 3;
    is($one->_dur_order, [qw/long medium short/], "max medium is n-1");
};

subtest next_concurrent => sub {
    my $state = {
        running    => 0,
        durations  => {short => 0, medium => 0, long => 0},
        categories => {general => 0, immiscible => 0, isolation => 0},
    };
    my $control = mock $CLASS => (override => [_running_state => sub { $state }]);

    my $count = 3;
    my $run = mock {} => (add => [ job_count => sub { $count }]);
    my $one = $CLASS->new(run => $run, dir => $dir, queue => 1, jobs_file => 1, stages => {});

    $one->{pending}->{default} = [
        {job_id => 1,  category => 'general',    duration => 'short'},
        {job_id => 2,  category => 'general',    duration => 'medium'},
        {job_id => 3,  category => 'general',    duration => 'long'},
        {job_id => 4,  category => 'general',    duration => 'long'},
        {job_id => 5,  category => 'general',    duration => 'medium'},
        {job_id => 9,  category => 'immiscible', duration => 'long'},
        {job_id => 12, category => 'immiscible', duration => 'long'},
        {job_id => 13, category => 'isolation',  duration => 'short'},
        {job_id => 14, category => 'isolation',  duration => 'medium'},
    ];

    like($one->_next_concurrent('default'), {job_id => 9}, "Got immiscible-long first");
    $state->{categories}->{immiscible}++;
    $state->{durations}->{long}++;
    $state->{running}++;

    like($one->_next_concurrent('default'), {job_id => 3}, "Got general-long");
    $state->{categories}->{general}++;
    $state->{durations}->{long}++;
    $state->{running}++;

    like($one->_next_concurrent('default'), {job_id => 2}, "Got general-medium");
    $state->{categories}->{general}++;
    $state->{durations}->{medium}++;
    $state->{running}++;

    like($one->_next_concurrent('default'), {job_id => 5}, "Got general-medium again");
    $state->{categories}->{general}++;
    $state->{durations}->{medium}++;
    $state->{running}++;

    like($one->_next_concurrent('default'), {job_id => 1}, "Got general-short");
    $state->{categories}->{general}++;
    $state->{durations}->{medium}++;
    $state->{running}++;

    $state->{categories}->{immiscible}--;
    $state->{durations}->{long}--;
    $state->{running}--;
    like($one->_next_concurrent('default'), {job_id => 12}, "Got next immiscbile");
    $state->{categories}->{immiscible}++;
    $state->{durations}->{long}++;

    $state->{categories}->{isolation}++;
    is($one->_next_concurrent('default'), undef, "Nothing with isolation running");
    $state->{categories}->{isolation}--;

    like($one->_next_concurrent('default'), {job_id => 4}, "Use long if nothing else works, even though we are saturated");
    $state->{categories}->{general}++;
    $state->{durations}->{long}++;
    $state->{running}++;

    is($one->_next_concurrent('default'), undef, "Only isolation left, but we have stuff running so we need to wait");

    $state = {};
    like($one->_next_concurrent('default'), {job_id => 14}, "Nothing running so we can grab isolation");
    $state->{running} = 1;

    is($one->_next_concurrent('default'), undef, "Only isolation left, but we have stuff running so we need to wait");

    $state->{running} = 0;
    like($one->_next_concurrent('default'), {job_id => 13}, "Nothing running so we can grab isolation");

    $one->{pending}->{default} = [
        {job_id => 100, category => 'general', duration => 'short', conflicts => ['a']},
        {job_id => 101, category => 'general', duration => 'short', conflicts => ['a']},
    ];

    $state = {};
    like($one->_next_concurrent('default'), {job_id => 100}, "No conflicts");

    $state->{running} = 1;
    $state->{conflicts} = {a => 1};
    is($one->_next_concurrent('default'), undef, "next has conflict, so wait");

    $state = {};
    like($one->_next_concurrent('default'), {job_id => 101}, "No conflicts");
};

subtest next_iter => sub {
    my $one = $CLASS->new(run => 1, dir => $dir, queue => 1, jobs_file => 1, stages => {}, wait_time => 0);

    my $todo;
    $one->{todo}->{default} = \$todo;

    my $pending = [];
    $one->{pending}->{default} = $pending;

    my $lock = 0;
    my ($task, $polled, $waited, $unlocked);
    my $c1 = mock $CLASS => (
        override => [
            lock         => sub { $lock },
            unlock       => sub { $unlocked++ },
            poll_tasks   => sub { $polled++ },
            wait_on_jobs => sub { $waited++ },
        ],
        add => [
            next_meth => sub { $task },
        ],
    );

    $task = 123;
    my $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, 123, "Got the task");
    ok(!$unlocked, "Did not unlock");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $task = undef;
    ($unlocked, $polled, $waited) = (0,0,0);
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, undef, "no task to do");
    ok(!$unlocked, "Did not unlock");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $task = 123;
    $one->{lock_file} = 1;
    ($unlocked, $polled, $waited) = (0,0,0);
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, undef, "did not get the task due to lock");
    is($unlocked, 1, "unlock was called");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $lock = 1;
    $task = 123;
    $one->{lock_file} = 1;
    ($unlocked, $polled, $waited) = (0,0,0);
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, undef, "did not get the task due to no-todo and empty pending");
    is($unlocked, 1, "unlocked");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $todo = 1;
    $lock = 1;
    $task = 123;
    $one->{lock_file} = 1;
    ($unlocked, $polled, $waited) = (0,0,0);
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, 123, "Got the task");
    is($unlocked, 0, "Saved the lock");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $todo = 0;
    push @$pending => 1;
    $lock = 1;
    $task = 123;
    $one->{lock_file} = 1;
    ($unlocked, $polled, $waited) = (0,0,0);
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, 123, "Got the task");
    is($unlocked, 0, "Saved the lock");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $task = 123;
    delete $one->{lock_file};
    ($unlocked, $polled, $waited) = (0,0,0);
    $one->{_pids} = { map {$_ => {}} 1 .. 11 };
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, undef, "No task because we are over max");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");

    $task = 123;
    delete $one->{lock_file};
    ($unlocked, $polled, $waited) = (0,0,0);
    $one->{_pids} = { map {$_ => {}} 1 .. 9 };
    $got = $one->_next_iter('default', 1, 10, 'next_meth');
    is($got, 123, "Got the task");
    is($polled, 1, "Polled once");
    is($waited, 1, "Waited once");
};

subtest _next => sub {
    my $count = 1;
    my $run = mock {} => (add => [ job_count => sub { $count }]);
    my $one = $CLASS->new(run => $run, dir => $dir, queue => 1, jobs_file => 1, stages => {}, wait_time => 0);

    my $todo = 1;
    $one->{todo}->{default} = \$todo;

    my $pending = [1];
    $one->{pending}->{default} = $pending;

    my $end = 0;
    $one->{end_loop_cb} = sub { $end };

    my $task;
    my $loop;
    my $iter;
    my $control = mock $CLASS => (
        override => [
            _next_iter => sub {
                my $self = shift;
                $iter ||= [];
                push @$iter => [@_];
                $self->$loop(@_) if $loop;
                return $task;
            },
        ],
    );

    $task = 123;
    is($one->_next('default'), 123, "Got task");
    is($iter, [['default', 0, 1, '_next_simple']], "Got args for inner loop");

    $iter = undef;
    $task = 123;
    $end = 1;
    is($one->_next('default'), undef, "Loop ended via callback, no task");
    is($iter, undef, "Inner loop never called");

    $end = 0;
    $todo = 0;
    @$pending = ();
    $one->{queue_ended} = 1;
    is($one->_next('default'), undef, "nothing to do, no task");
    is($iter, undef, "Inner loop never called");

    $end = 0;
    $todo = 1;
    @$pending = ();
    $one->{queue_ended} = 1;
    is($one->_next('default'), 123, "got task because todo is true");

    $end = 0;
    $todo = 0;
    @$pending = (1);
    $one->{queue_ended} = 1;
    is($one->_next('default'), 123, "got task because we have pending items");

    $end = 0;
    $todo = 0;
    @$pending = ();
    $one->{queue_ended} = 0;
    is($one->_next('default'), 123, "got task because queue has not ended");

    $count = 2;
    $iter = undef;
    is($one->_next('default'), 123, "got task because queue has not ended");
    is($iter, [['default', 0, 2, '_next_concurrent']], "Got args for inner loop");

    $count = 2;
    $iter = undef;
    $task = 0;
    $loop = sub {
        my $self = shift;
        my ($stage, $iter, $max, $next_meth) = @_;
        $task = 124 if $iter >= 3;
    };
    is($one->_next('default'), 124, "got task because queue has not ended");
    is(
        $iter,
        [
            ['default', 0, 2, '_next_concurrent'],
            ['default', 1, 2, '_next_concurrent'],
            ['default', 2, 2, '_next_concurrent'],
            ['default', 3, 2, '_next_concurrent'],
        ],
        "Got args for inner loop"
    );
};

done_testing;
