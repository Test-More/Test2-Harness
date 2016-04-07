use Test2::Bundle::Extended -target => 'Test2::Harness::Result';

use Test2::Harness::Fact;

can_ok $CLASS => qw{
    file name job nested

    is_subtest in_subtest

    total      failed
    start_time stop_time
    exit

    plans
    planning
    plan_errors

    facts
};

subtest init => sub {
    like(
        dies { $CLASS->new() },
        qr/'file' is a required attribute/,
        "Need 'file'"
    );

    like(
        dies { $CLASS->new( file => 'file.t' ) },
        qr/'job' is a required attribute/,
        "Need 'job'"
    );

    like(
        dies { $CLASS->new(file => 'file.t', job => 1) },
        qr/'name' is a required attribute/,
        "Need 'name'"
    );

    my $one = $CLASS->new(
        file => 'file.t',
        job  => 1,
        name => 'file',
    );

    like(
        $one,
        object {
            call nested      => 0;
            call start_time  => T();
            call total       => 0;
            call failed      => 0;
            call plans       => [];
            call planning    => [];
            call plan_errors => [];
            call facts       => [];
        },
        "Got defaults"
    );
};


subtest stop => sub {
    my $one = $CLASS->new(
        file => 'file.t',
        job  => 1,
        name => 'file',
    );

    like(
        $one,
        object {
            call stop_time => undef;
            call exit => undef;
            call plan_errors => [DNE()];
        },
        "Stop data not yet present"
    );

    $one->stop(42);
    like(
        $one,
        object {
            call stop_time => T();
            call exit => 42;

            # No plan, so plan errors occur, they get checked later though
            call plan_errors => [T()];
        },
        "Stop data present"
    );
};

subtest passed => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    is($one->passed, undef, "Cannot tell yet");
    $one->set_stop_time(1);

    is($one->passed, 1, "passed");
    $one->set_exit(1);
    ok(!$one->passed, "exit value prevents passing");
    $one->set_exit(0);

    is($one->passed, 1, "passed");
    $one->set_failed(1);
    ok(!$one->passed, "failure prevents passing");
    $one->set_failed(0);

    is($one->passed, 1, "passed");
    $one->set_plan_errors([1]);
    ok(!$one->passed, "plan errors prevent passing");
    $one->set_plan_errors([]);

    is($one->passed, 1, "passed");
};

subtest bump_failed => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    is($one->failed, 0, "no failures");

    $one->bump_failed;
    is($one->failed, 1, "bumped failure");

    $one->bump_failed(3);
    is($one->failed, 4, "bumped failure by 4");
};

subtest add_facts => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    my @ran;
    my $mock = mock $CLASS => (
        override => [ add_fact => sub { push @ran => pop } ],
    );

    $one->add_facts(qw/a b c d e/);

    is(\@ran, [qw/a b c d e/], "Ran for each item");
};

subtest add_fact => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file', nested => 4);

    my $f = Test2::Harness::Fact->new;

    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    ok(!$one->failed, "no failures yet");

    $f = Test2::Harness::Fact->new(increments_count => 1);
    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    ref_is($one->planning->[-1], $f, "Added to planning");
    ok(!$one->failed, "no failures yet");
    is($one->total, 1, "bumped count");

    $f = Test2::Harness::Fact->new(increments_count => 1, causes_fail => 1);
    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    ref_is($one->planning->[-1], $f, "Added to planning");
    is($one->failed, 1, "a failure");
    is($one->total, 2, "bumped count");

    $f = Test2::Harness::Fact->new(increments_count => 1, terminate => 1);
    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    ref_is($one->planning->[-1], $f, "Added to planning");
    is($one->failed, 2, "a failure");
    is($one->total, 3, "bumped count");

    $f = Test2::Harness::Fact->new(sets_plan => [1]);
    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    ref_is($one->planning->[-1], $f, "Added to planning");
    ref_is($one->plans->[-1], $f, "Added to plans");
    is($one->failed, 2, "not a failure");
    is($one->total, 3, "not a count bumper");

    $f = Test2::Harness::Fact->new(is_subtest => 'foo', nested => 1, result => $CLASS->new(nested => 2, file => 1, job => 1, name => 'foo'));
    $one->add_fact($f);
    ref_is($one->facts->[-1], $f, "Added fact");
    is($f->nested, 4, "Updated nesting");
    is($f->result->nested, 5, "Updated nesting");
};

subtest update_nest => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file', nested => 4);
    my $f1 = Test2::Harness::Fact->new(nested => 5);
    my $f2 = Test2::Harness::Fact->new(is_subtest => 'foo', nested => 1, result => $CLASS->new(nested => 2, file => 1, job => 1, name => 'foo'));

    $one->add_facts($f1, $f2);
    $one->update_nest(5);
    is($one->nested, 5, "set our nesting");
    is($f1->nested, 5, "set child nesting");
    is($f2->nested, 5, "set child subtest nesting");
};

subtest _check_numbers => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    $one->_check_numbers;
    ok(!@{$one->plan_errors}, "no plan errors yet");

    $one->add_facts(
        Test2::Harness::Fact->new(increments_count => 1, number => 1),
        Test2::Harness::Fact->new(increments_count => 0),
        Test2::Harness::Fact->new(increments_count => 1, number => 2),
        Test2::Harness::Fact->new(increments_count => 1, number => 4),
        Test2::Harness::Fact->new(increments_count => 1, number => 5),
        Test2::Harness::Fact->new(increments_count => 0),
        Test2::Harness::Fact->new(increments_count => 1, number => 5),
    );

    $one->_check_numbers;
    is(
        $one->plan_errors,
        [
            "Some test numbers were seen more than once: 5",
            "Some test numbers were seen out of order: 4, 5"
        ],
        "Got errors"
    );
};

subtest _check_plan => sub {
    my $make = sub {  $CLASS->new(file => 'file.t', job  => 1, name => 'file') };

    my $one = $make->();
    $one->_check_plan;
    $one->_check_plan; #insure message is not added again
    is(
        $one->plan_errors,
        [ 'No events were ever seen!' ],
        "Need events"
    );

    $one = $make->();
    $one->add_fact(Test2::Harness::Fact->new);
    $one->_check_plan;
    $one->_check_plan;
    is(
        $one->plan_errors,
        [ 'No plan was ever set.' ],
        "Need a plan"
    );

    $one = $make->();
    $one->add_fact(Test2::Harness::Fact->new(sets_plan => [1]));
    $one->add_fact(Test2::Harness::Fact->new(sets_plan => [1]));
    $one->_check_plan;
    $one->_check_plan;
    is(
        $one->plan_errors,
        [
            'Multiple plans were set.',
            "Planned to run 1 test(s) but ran 0."
        ],
        "Multiple plans and bad count"
    );

    $one = $make->();
    $one->add_fact(Test2::Harness::Fact->new(increments_count => 1));
    $one->add_fact(Test2::Harness::Fact->new(sets_plan => [1]));
    $one->add_fact(Test2::Harness::Fact->new(increments_count => 1));
    $one->_check_plan;
    $one->_check_plan;
    is(
        $one->plan_errors,
        [
            'Plan must come before or after all testing, not in the middle.',
            "Planned to run 1 test(s) but ran 2."
        ],
        "Middle Plan and bad count"
    );

    $one = $make->();
    $one->add_fact(Test2::Harness::Fact->new(sets_plan => [1]));
    $one->add_fact(Test2::Harness::Fact->new(increments_count => 1));
    $one->_check_plan;
    $one->_check_plan;
    is(
        $one->plan_errors,
        [],
        "No errors"
    );
};

done_testing;
