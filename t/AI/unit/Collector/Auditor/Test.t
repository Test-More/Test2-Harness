use Test2::V0;
use v5.38;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor::Test;

# The auditor is the collector pipeline's processor. It passes every event
# through, tracks the running test's verdict, emits state-transition events
# (starting / failing / diagnosing / completed) as additional events, and
# emits a final-state event when it sees the process-exit event.

sub ev ($facet_data) { return Test2::Harness2::Event->new(facet_data => $facet_data) }

sub assert_ev ($pass, %extra) {
    return ev({assert => {pass => $pass ? 1 : 0, details => $extra{details} // 'an assertion', (defined $extra{number} ? (number => $extra{number}) : ())}, %{$extra{more} // {}}});
}

sub exit_ev ($all) {
    return ev({harness_process_exit => {all => $all, err => $all >> 8, sig => $all & 127, dmp => 0}});
}

# Pull the transition state names out of a list of emitted events, in order.
sub transitions (@events) {
    return map { $_->facet_data->{harness_state_transition}{state} }
        grep { $_->facet_data->{harness_state_transition} } @events;
}

sub final_of (@events) {
    my ($fs) = grep { $_->facet_data->{harness_final_state} } @events;
    return $fs ? $fs->facet_data->{harness_final_state} : undef;
}

# Feed a list of events through the auditor, return ALL emitted events.
sub run_auditor ($auditor, @events) {
    return map { $auditor->process_event($_) } @events;
}

subtest does_processor_role => sub {
    ok(
        Test2::Harness2::Collector::Auditor::Test->DOES('Test2::Harness2::Collector::Role::Processor'),
        "auditor consumes the Processor role",
    );
};

subtest starting_transition_first => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = $auditor->process_event(assert_ev(1));

    my @states = transitions(@out);
    is($states[0], 'starting', "first emitted transition is 'starting'");

    # The triggering event itself is passed through.
    ok(
        (grep { $_->facet_data->{assert} } @out),
        "the original assert event is passed through",
    );
};

subtest passthrough_and_pass_verdict => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(1), assert_ev(1), exit_ev(0));

    is($auditor->pass_count, 2, "counted two passing assertions");
    is($auditor->fail_count, 0, "no failures");
    ok($auditor->passing, "auditor reports passing");

    my $fs = final_of(@out);
    is($fs->{pass},            1, "final state pass=1");
    is($fs->{fail_count},      0, "final state fail_count=0");
    is($fs->{pass_count},      2, "final state pass_count=2");
    is($fs->{assertion_count}, 2, "final state assertion_count=2");
};

subtest failing_assert_fails_and_transitions => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(1), assert_ev(0), exit_ev(0));

    ok($auditor->failing, "auditor reports failing after a failed assertion");
    is($auditor->fail_count, 1, "one failure counted");

    my @states = transitions(@out);
    ok((grep { $_ eq 'failing' } @states), "a 'failing' transition was emitted");

    my $fs = final_of(@out);
    is($fs->{pass}, 0, "final state pass=0");
};

subtest amnesty_does_not_count_as_failure => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    run_auditor(
        $auditor,
        assert_ev(0, more => {amnesty => [{tag => 'TODO', details => 'later'}]}),
        exit_ev(0),
    );

    is($auditor->fail_count, 0, "a TODO (amnestied) failure does not count");
    ok($auditor->passing, "auditor still passing with only amnestied failures");
};

subtest nonzero_exit_fails => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(1), exit_ev(256));    # exit code 1

    is($auditor->fail_count, 1, "non-zero exit counts as a failure");
    ok($auditor->failing, "auditor fails on non-zero child exit");

    my $fs = final_of(@out);
    is($fs->{pass}, 0, "final state pass=0 on non-zero exit");
    is($fs->{exit}, 256, "raw exit status recorded");
};

subtest plan_recorded_in_final_state => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor(
        $auditor,
        ev({plan => {count => 1, skip => 0, details => ''}}),
        assert_ev(1),
        exit_ev(0),
    );

    my $fs = final_of(@out);
    is($fs->{plan}{count}, 1, "plan count carried into final state");
};

subtest halt_bailout_fails => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(1), ev({control => {halt => 1, details => 'bail'}}), exit_ev(0));

    ok($auditor->failing, "bail-out marks the test failing");

    my $fs = final_of(@out);
    is($fs->{pass}, 0, "final state pass=0 after bail-out");
    is($fs->{halt}, 'bail', "halt reason recorded");
};

subtest diagnosing_transition => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor(
        $auditor,
        assert_ev(1),
        ev({info => [{tag => 'DIAG', debug => 1, details => 'a diagnostic'}]}),
        exit_ev(0),
    );

    my @states = transitions(@out);
    ok((grep { $_ eq 'diagnosing' } @states), "a 'diagnosing' transition was emitted");
};

subtest completed_transition_on_exit => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(1), exit_ev(0));

    my @states = transitions(@out);
    is($states[-1], 'completed', "'completed' is the last transition");

    # Ordering: the exit event passes through before the final-state event.
    my @kinds = map {
          $_->facet_data->{harness_process_exit} ? 'exit'
        : $_->facet_data->{harness_final_state}  ? 'final'
        :                                          ()
    } @out;
    is(\@kinds, ['exit', 'final'], "exit event precedes the final-state event");
};

subtest transitions_latch_once => sub {
    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = run_auditor($auditor, assert_ev(0), assert_ev(0), exit_ev(256));

    my @failing = grep { $_ eq 'failing' } transitions(@out);
    is(scalar(@failing), 1, "'failing' transition emitted only once despite multiple failures");
};

done_testing;
