use Test2::Bundle::Extended -target => 'Test2::Harness::Job';
use Test2::Event::Generic;
use Test2::Harness::Parser;

can_ok($CLASS, qw/id file listeners parser proc result/);

subtest init => sub {
    like(
        dies { $CLASS->new() },
        qr/job 'id' is required/,
        "ID is required"
    );

    like(
        dies { $CLASS->new(id => 1) },
        qr/job 'file' is required/,
        "file is required"
    );

    my $one = $CLASS->new(id => 1, file => 'fake.t');
    isa_ok($one, $CLASS);

    is($one->listeners, [], "empty listeners by default");
    isa_ok($one->result, 'Test2::Harness::Result');
    like(
        $one->result,
        {
            file => 'fake.t',
            name => 'fake.t',
            job  => 1,
        },
        "result is set for job"
    );
};

subtest start => sub {
    my @notify;
    my $mc = mock $CLASS => (
        override => [
            notify => sub {
                shift;
                @notify = @_;
            }
        ],
    );
    my $mr = mock 'My::Runner' => (
        add => [
            start => sub { return ('proc', 'result', [@_]) },
        ],
    );
    my $mp = mock 'My::Parser' => (
        add => [
            new => sub {
                my $class = shift;
                my %proto = @_;
                return bless \%proto, $class;
            }
        ],
    );

    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
    );

    $one->start(
        runner       => 'My::Runner',
        parser_class => 'My::Parser',
        start_args   => {a => 1},
    );

    like(
        $one,
        {
            id   => 1,
            file => 'fake.t',
            proc => 'proc',
            parser => {
                job => 1,
                proc => 'proc',
            },
        },
        "Start did it's thing"
    );

    like(
        \@notify,
        [
            {file => 'fake.t'},
            'result',
            [
                'My::Runner',
                'fake.t',
                a => 1,
                job => 1,
            ],
        ],
        "Cheated, notifications has correct stuff"
    );
};

subtest notify => sub {
    my @notify;
    my $one = $CLASS->new(
        id        => 1,
        file      => 'fake.t',
        listeners => [
            sub {
                my $j = shift;
                push @notify => ($j->id, @_);
            }
        ],
    );

    my $event = Test2::Event::ProcessStart->new(
        file => 't/some-file.t',
    );

    $one->notify($event);

    is(
        \@notify,
        [1, $event],
        "Added event via listener"
    );
    is($one->result->events->[-1], $event, "Event added to result");

    my $event2 = Test2::Event::ProcessStart->new(
        file => 't/another.t',
    );

    $one->notify($event2);

    like(
        \@notify,
        [1, $event, 1, $event2],
        "Added event via listener"
    );
};

subtest step => sub {
    my @things = (
        ['a'],
        ['b'],
        [],
        [],
        ['c'],
    );

    my $m = mock $CLASS => (
        override => [notify => sub { }],
    );

    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
        parser => mock {} => (
            add => [step => sub { @{shift @things || []} }],
        ),
    );

    ok($one->step,  "true, got events");
    ok($one->step,  "true, got events");
    ok(!$one->step, "false, no events");
    ok(!$one->step, "false, no events");
    ok($one->step,  "true, got events");
};

subtest timeout => sub {
    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
        proc => mock({exit => 0}),
    );

    is($one->timeout, 60, "Worst case timeout is 60 seconds");

    $one->proc->{exit} = 1;
    is($one->timeout, 0, "if the proc exited false then timeout is 0");

    $one->proc->{exit} = 0;
    $one->result->set_plans([mock {} => (add => [sets_plan => sub { 10 }])]);
    $one->result->set_total(10);
    is($one->timeout, 0, "Have plan, and total matches");

    $one->result->set_total(5);
    is($one->timeout, 60, "Have plan, total came up short");

    $one->result->set_plans([mock {} => (add => [sets_plan => sub { 0 }])]);
    is($one->timeout, 0, "Plan is to skip all");
};

subtest is_done => sub {
    my @events;
    my $parser = mock 'obj' => (
        add => [step => sub { @events }],
    );

    my $proc = mock({is_done => 1});
    my $one = $CLASS->new(
        id     => 1,
        file   => 'fake.t',
        parser => $parser,
        proc => $proc,
    );

    ok(!$one->is_done, "not done");

    $one->set__done(1);
    ok($one->is_done, "done");

    $one->set__done(0);
    $one->proc->{is_done} = 1;

    @events = Test2::Event::Ok->new(pass => 1 );
    ok(!$one->is_done, "Never done while step is true ($_)") for 1 .. 5;
    @events = ();

    $one = $CLASS->new(
        id     => 1,
        file   => 'fake.t',
        parser => $parser,
        proc => $proc,
    );

    $one->notify(
        Test2::Event::Plan->new(max => 1),
        Test2::Event::Ok->new(pass => 1),
    );

    ok($one->is_done, "no timeout with completed plan");

    my $m = mock $CLASS => (
        override => [timeout => sub { 5 }],
    );
    $one = $CLASS->new(
        id     => 1,
        file   => 'fake.t',
        parser => $parser,
        proc   => $proc,
    );
    ok(!$one->is_done, "not done");
    ok(my $old = $one->_timeout, "set timeout");

    @events = Test2::Event::Ok->new(pass => 1 );
    ok(!$one->is_done, "still not done");
    ok(!$one->_timeout, "cleared timeout");

    @events = ();
    ok(!$one->is_done, "still not done");
    ok($old < $one->_timeout, "reset timeout") or diag "$old\n" . $one->_timeout;
    ok(!$one->is_done, "still not done");
    $one->set__timeout($old - 10);
    ok($one->is_done, "timed out, done");

    like(
        $one->result->events,
        array {
            event UnexpectedProcessExit => sub {
                call summary     => 'Process has exited but the event stream does not appear complete. Waiting 5 seconds...';
                call diagnostics => 1;
            };
            event Ok => sub {
                call pass => 1;
            };
            event TimeoutReset => sub {
                call summary     => 'Event received, timeout reset.';
                call diagnostics => 1;
            };
        },
        "Got events explaining timeout"
    );
};

done_testing;
