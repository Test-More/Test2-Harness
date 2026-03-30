use Test2::V0 -target => 'Test2::Harness::Scheduler';

# A minimal fake runner object that satisfies what Scheduler needs
{
    package FakeRunner;
    sub new    { bless {}, shift }
    sub ready  { 1 }
    sub start  { }
}

my $runner = FakeRunner->new;

subtest constructor_requires_runner => sub {
    like(
        dies { CLASS->new() },
        qr/runner.*required/i,
        "runner is required"
    );
};

subtest construction => sub {
    my $sched = CLASS->new(runner => $runner);
    ok($sched, "scheduler constructed");
};

subtest initial_state => sub {
    my $sched = CLASS->new(runner => $runner);
    is(ref($sched->run_order),      'ARRAY', "run_order is an arrayref");
    is(ref($sched->runs),           'HASH',  "runs is a hashref");
    is(ref($sched->running),        'HASH',  "running is a hashref");
    is(ref($sched->children),       'HASH',  "children is a hashref");
    is(scalar @{$sched->run_order}, 0,       "run_order starts empty");
    is($sched->terminated,          undef,   "terminated starts undef");
};

subtest overall_status => sub {
    my $sched = CLASS->new(runner => $runner);
    my $status = $sched->overall_status;
    ok(ref($status) eq 'HASH',  "overall_status returns a hashref");
    ok($status->{title},        "has a title");
    ok(ref($status->{tables}) eq 'ARRAY', "has tables arrayref");
};

subtest terminate => sub {
    my $sched = CLASS->new(runner => $runner);

    my $reason = $sched->terminate('test_reason');
    is($reason, 'test_reason', "terminate returns the reason");
    is($sched->terminated, 'test_reason', "terminated attribute set");

    # Calling terminate again should not override existing value
    my $reason2 = $sched->terminate('other_reason');
    is($reason2, 'test_reason', "second terminate returns original reason");
};

subtest stop_flag => sub {
    my $sched = CLASS->new(runner => $runner);
    $sched->stop;
    # stop sets the internal +STOP flag; we can't read it directly but
    # we verify the scheduler object is still intact
    ok($sched, "scheduler still alive after stop called");
};

subtest register_child => sub {
    my $sched = CLASS->new(runner => $runner);
    $sched->register_child(12345, 'worker', 'test_child', undef);
    ok(exists $sched->children->{12345}, "child registered by pid");
    is($sched->children->{12345}{type}, 'worker',     "child type correct");
    is($sched->children->{12345}{name}, 'test_child', "child name correct");
};

subtest process_list => sub {
    my $sched = CLASS->new(runner => $runner);

    # No children, no running jobs
    my @list = $sched->process_list;
    is(scalar @list, 0, "empty process list initially");

    # Add a child
    $sched->register_child(99999, 'helper', 'helper_proc', undef);

    @list = $sched->process_list;
    is(scalar @list, 1, "one entry after registering a child");
    is($list[0]{pid},  99999,        "child pid in list");
    is($list[0]{type}, 'helper',     "child type in list");
    is($list[0]{name}, 'helper_proc', "child name in list");
};

subtest kill_delegates_to_abort => sub {
    my $sched = CLASS->new(runner => $runner);
    # kill() just calls abort(); verify it does not die
    ok(lives { $sched->kill }, "kill does not die");
};

done_testing;
