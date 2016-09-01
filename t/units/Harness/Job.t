use Test2::Bundle::Extended -target => 'Test2::Harness::Job';

can_ok($CLASS, qw/id file listeners parser proc result subtests/);

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
    is($one->subtests, {}, "empty subtests");
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
            {start => 'fake.t'},
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
    my @facts;
    my $one = $CLASS->new(
        id        => 1,
        file      => 'fake.t',
        listeners => [
            sub {
                my $j = shift;
                push @facts => ($j->id, @_);
            }
        ],
    );

    my $fact = Test2::Harness::Fact->new(
        output => 'aaa',
        handle => 'STDOUT',
    );

    $one->notify($fact);

    is(
        \@facts,
        [1, $fact],
        "Added fact via listener"
    );
    is($one->result->facts->[-1], $fact, "Fact added to result");

    my $fact2 = Test2::Harness::Fact->new(
        output => 'aaa',
        handle => 'STDOUT',
        is_subtest => 'x',
    );

    $one->notify($fact2);

    like(
        \@facts,
        [1, $fact, 1, {is_subtest => 'x'}],
        "Added fact via listener"
    );
};

subtest subtest_result => sub {
    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
    );

    my $f = Test2::Harness::Fact->new;

    ref_is($one->subtest_result($f), $one->result, "No subtest, root result");

    $f->set_in_subtest('x');

    my $st = $one->subtest_result($f);
    like($st, {name => 'x'}, "In subtest, create result for subtest");
    ref_is($st, $one->subtest_result($f), "Got the same subtest result");
};

subtest end_subtest => sub {
    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
    );

    my $f = Test2::Harness::Fact->new(
        summary          => 'xyz summary',
        number           => 1,
        increments_count => 1,
        in_subtest       => 'foo',
    );
    ref_is($one->end_subtest($f), $f, "Got original event back");

    $f->set_is_subtest('x');

    my $f2 = $one->end_subtest($f);

    like(
        $f2,
        {
            result           => T(),
            number           => 1,
            name             => 'xyz summary',
            in_subtest       => 'foo',
            is_subtest       => 'x',
            increments_count => 1,
        },
        "Got result fact"
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
        proc => mock({ exit => 0 }),
    );

    is($one->timeout, 60, "Worst case timeout is 60 seconds");

    $one->proc->{exit} = 1;
    is($one->timeout, 0, "if the proc exited false then timeout is 0");

    $one->proc->{exit} = 0;
    $one->result->set_plans([mock {} => (add => [ sets_plan => sub {[10]} ])]);
    $one->result->set_total(10);
    is($one->timeout, 0, "Have plan, and total matches");

    $one->result->set_total(5);
    is($one->timeout, 60, "Have plan, total came up short");

    $one->result->set_plans([mock {} => (add => [ sets_plan => sub {[0]} ])]);
    is($one->timeout, 0, "Plan is to skip all");
};

subtest is_done => sub {
    my $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
        proc => mock({ is_done => 0 }),
    );

    ok(!$one->is_done, "not done");

    $one->set__done(1);
    ok($one->is_done, "done");

    $one->set__done(0);
    $one->proc->{is_done} = 1;

    my $step = 1;
    my $m = mock $CLASS => (
        override => [ step => sub { $step } ],
    );

    ok(!$one->is_done, "Never done while step is true ($_)") for 1 .. 5;

    $one->notify(
        Test2::Harness::Fact->new( sets_plan => [ 1 ] ),
        Test2::Harness::Fact->new( increments_count => 1 ),
    );

    $step = 0;
    ok($one->is_done, "no timeout with completed plan");


    $m->override(timeout => sub { 5 });
    $one = $CLASS->new(
        id   => 1,
        file => 'fake.t',
        proc => mock({ is_done => 1 }),
    );
    ok(!$one->is_done, "not done");
    ok(my $old = $one->_timeout, "set timeout");

    $step = 1;
    ok(!$one->is_done, "still not done");
    ok(!$one->_timeout, "cleared timeout");

    $step = 0;
    ok(!$one->is_done, "still not done");
    ok($old < $one->_timeout, "reset timeout") or diag "$old\n" . $one->_timeout;
    ok(!$one->is_done, "still not done");
    $one->set__timeout($old - 10);
    ok($one->is_done, "timed out, done");

    like(
        $one->result->facts,
        array {
            item object {
                prop blessed => 'Test2::Harness::Fact';
                call summary => "Process has exited but the event stream does not appear complete. Waiting 5 seconds...\n";
                call parse_error => 1;
                call diagnostics => 1;
            };

            item object {
                prop blessed => 'Test2::Harness::Fact';
                call summary => "Event received, timeout reset.\n";
                call parse_error => 1;
                call diagnostics => 1;
            };

            item object {
                prop blessed => 'Test2::Harness::Fact';
                call result => T();
            };
        },
        "Got facts explaining timeout"
    );
};

done_testing;
