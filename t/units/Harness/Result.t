use Test2::Bundle::Extended -target => 'Test2::Harness::Result';

use Test2::Event::Generic;
use Test2::Event::ProcessStart;

can_ok $CLASS => qw{
    file name job

    total      failed
    start_time stop_time
    exit

    plans

    events
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
            call start_time  => T();
            call total       => 0;
            call failed      => 0;
            call events      => [];
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
        },
        "Stop data not yet present"
    );

    $one->stop(42);
    like(
        $one,
        object {
            call stop_time => T();
            call exit => 42;
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
};

subtest bump_failed => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    is($one->failed, 0, "no failures");

    $one->bump_failed;
    is($one->failed, 1, "bumped failure");

    $one->bump_failed(3);
    is($one->failed, 4, "bumped failure by 4");
};

subtest add_events => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file');

    my @ran;
    my $mock = mock $CLASS => (
        override => [ add_event => sub { push @ran => pop } ],
    );

    $one->add_events(qw/a b c d e/);

    is(\@ran, [qw/a b c d e/], "Ran for each item");
};

subtest add_event => sub {
    my $one = $CLASS->new(file => 'file.t', job  => 1, name => 'file', nested => 4);

    my $e = Test2::Event::Generic->new;
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    ok(!$one->failed, "no failures yet");

    $e = Test2::Event::Generic->new(increments_count => 1);
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    ok(!$one->failed, "no failures yet");
    is($one->total, 1, "bumped count");

    $e = Test2::Event::Generic->new(increments_count => 1, causes_fail => 1);
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    is($one->failed, 1, "a failure");
    is($one->total, 2, "bumped count");

    $e = Test2::Event::Generic->new(increments_count => 1, terminate => 1);
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    is($one->failed, 2, "a failure");
    is($one->total, 3, "bumped count");

    $e = Test2::Event::Plan->new(max => 1);
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    ref_is($one->plans->[-1], $e, "Added to plans");
    is($one->failed, 2, "not a failure");
    is($one->total, 3, "not a count bumper");

    $e = Test2::Event::Plan->new(directive => 'no_plan');
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
    ref_is_not($one->plans->[-1], $e, "Not added to plans");
    is($one->failed, 2, "not a failure");
    is($one->total, 3, "not a count bumper");

    $e = Test2::Event::Generic->new(subtest_id => 'foo', nested => 1);
    $one->add_event($e);
    ref_is($one->events->[-1], $e, "Added event");
};

done_testing;
