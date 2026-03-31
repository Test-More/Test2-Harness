use Test2::V0 -target => 'App::Yath::Schema::ImportModes';

use App::Yath::Schema::ImportModes qw/
    is_mode mode_check
    event_in_mode record_all_events record_subtest_events
/;
use App::Yath::Schema::ImportModes '%MODES';

subtest is_mode => sub {
    ok(is_mode('summary'),  "summary is a valid mode");
    ok(is_mode('qvf'),      "qvf is a valid mode");
    ok(is_mode('qvfd'),     "qvfd is a valid mode");
    ok(is_mode('qvfds'),    "qvfds is a valid mode");
    ok(is_mode('complete'), "complete is a valid mode");

    ok(!is_mode(''),        "empty string is not a mode");
    ok(!is_mode(undef),     "undef is not a mode");
    ok(!is_mode('bogus'),   "unknown name is not a mode");
    ok(!is_mode(5),         "numeric value is not a mode (must be name)");
    ok(!is_mode(20),        "numeric value for complete is not a mode");
};

subtest mode_check => sub {
    ok(mode_check('summary',  'summary'),  "summary matches summary");
    ok(mode_check('complete', 'complete'), "complete matches complete");
    ok(mode_check('qvfd',     'qvfd'),     "qvfd matches qvfd");

    ok(!mode_check('complete', 'summary'), "complete does not match summary");
    ok(!mode_check('qvf',     'complete'), "qvf does not match complete");

    ok(dies { mode_check('bogus', 'summary') }, "invalid mode dies");
    ok(dies { mode_check('summary', 'bogus') }, "invalid want mode dies");
};

subtest record_all_events => sub {
    # complete mode always records all events
    ok(
        record_all_events(mode => 'complete', fail => 0, is_harness_out => 0),
        "complete mode records all events"
    );

    # summary mode never records events
    ok(
        !record_all_events(mode => 'summary', fail => 0, is_harness_out => 0),
        "summary mode records no events"
    );

    # harness output is always recorded (non-summary)
    ok(
        record_all_events(mode => 'qvf', fail => 0, is_harness_out => 1),
        "harness output always recorded in qvf"
    );

    # failing jobs in qvf+ get all events
    ok(
        record_all_events(mode => 'qvf', fail => 1, is_harness_out => 0),
        "failing job in qvf records all events"
    );

    ok(
        !record_all_events(mode => 'qvf', fail => 0, is_harness_out => 0),
        "passing job in qvf does not record all events"
    );
};

subtest record_subtest_events => sub {
    # If record_all_events is true, record_subtest_events is also true
    ok(
        record_subtest_events(mode => 'complete', fail => 0, is_harness_out => 0),
        "complete mode records subtest events"
    );

    # qvfds mode records subtest events
    ok(
        record_subtest_events(mode => 'qvfds', fail => 0, is_harness_out => 0),
        "qvfds records subtest events even for passing jobs"
    );

    # qvfd does not record subtest events for passing non-harness
    ok(
        !record_subtest_events(mode => 'qvfd', fail => 0, is_harness_out => 0),
        "qvfd does not record subtest events for passing jobs"
    );
};

subtest event_in_mode => sub {
    # A diag event at qvfd should be recorded for failing jobs
    my $diag_event = {
        is_diag        => 1,
        is_harness     => 0,
        is_time        => 0,
        is_subtest     => 0,
        nested         => 0,
    };
    ok(
        event_in_mode(mode => 'qvfd', fail => 1, is_harness_out => 0, event => $diag_event),
        "diag event in qvfd for failing job is recorded"
    );

    # qvfd records diag events regardless of pass/fail — that's the point of qvfd
    ok(
        event_in_mode(mode => 'qvfd', fail => 0, is_harness_out => 0, event => $diag_event),
        "diag event in qvfd is recorded even for passing job"
    );

    # qvf (below qvfd) does NOT record diag events for passing jobs
    my $plain_event = {is_diag => 0, is_harness => 0, is_time => 0, is_subtest => 0, nested => 0};
    ok(
        !event_in_mode(mode => 'qvf', fail => 0, is_harness_out => 0, event => $plain_event),
        "non-special event in qvf for passing job is not recorded"
    );

    # In complete mode, all events are recorded regardless
    ok(
        event_in_mode(mode => 'complete', fail => 0, is_harness_out => 0, event => $diag_event),
        "any event in complete mode is recorded"
    );

    # In summary mode, no events are recorded
    ok(
        !event_in_mode(mode => 'summary', fail => 0, is_harness_out => 0, event => $diag_event),
        "no events in summary mode"
    );

    # A harness event is always recorded at qvfd+
    my $harness_event = {
        is_diag        => 0,
        is_harness     => 1,
        is_time        => 0,
        is_subtest     => 0,
        nested         => 0,
    };
    ok(
        event_in_mode(mode => 'qvfd', fail => 0, is_harness_out => 0, event => $harness_event),
        "harness event in qvfd is recorded even for passing"
    );

    ok(dies { event_in_mode(mode => 'qvf', fail => 0, is_harness_out => 0) }, "'event' is required");
};

done_testing;
