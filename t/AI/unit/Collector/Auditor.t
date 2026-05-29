use Test2::V0;
use v5.38;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor;

# The auditor is the collector pipeline's processor for test jobs. It passes
# events through, validates the test (plan present, assertion numbers, plan vs
# count, subtests, errors, exit), emits state-transition events
# (starting / failing / diagnosing / completed) and a final-state event on
# exit, and computes the pass/fail verdict.

sub ev ($fd) { return Test2::Harness2::Event->new(facet_data => $fd) }

sub assert_f ($pass, %e) {
    my %f = (assert => {pass => $pass ? 1 : 0, details => $e{name} // 'an assertion'});
    $f{assert}{number} = $e{number} if exists $e{number};
    $f{amnesty}        = $e{amnesty} if $e{amnesty};
    $f{trace}          = {nested => $e{nested}} if $e{nested};
    return \%f;
}

sub plan_f ($count) { return {plan => {count => $count}} }
sub exit_f ($all)   { return {harness_process_exit => {all => $all, err => $all >> 8, sig => $all & 127, dmp => 0}} }

sub transitions (@events) {
    return map { $_->facet_data->{harness_state_transition}{state} }
        grep { $_->facet_data->{harness_state_transition} } @events;
}

sub final_of (@events) {
    my ($fs) = grep { $_->facet_data->{harness_final_state} } @events;
    return $fs ? $fs->facet_data->{harness_final_state} : undef;
}

sub run_auditor ($auditor, @facets) {
    return map { $auditor->process_event(ev($_)) } @facets;
}

subtest does_processor_role => sub {
    ok(
        Test2::Harness2::Collector::Auditor->DOES('Test2::Harness2::Collector::Role::Processor'),
        "auditor consumes the Processor role",
    );
};

subtest starting_then_completed_and_final_order => sub {
    my $a   = Test2::Harness2::Collector::Auditor->new;
    my @out = run_auditor($a, plan_f(1), assert_f(1, number => 1), exit_f(0));

    my @states = transitions(@out);
    is($states[0],  'starting',  "first transition is starting");
    is($states[-1], 'completed', "last transition is completed");

    my @kinds = map {
          $_->facet_data->{harness_process_exit} ? 'exit'
        : $_->facet_data->{harness_final_state}  ? 'final'
        :                                          ()
    } @out;
    is(\@kinds, ['exit', 'final'], "exit event precedes the final-state event");
};

subtest clean_pass => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    my @out = run_auditor($a, plan_f(2), assert_f(1, number => 1), assert_f(1, number => 2), exit_f(0));

    ok($a->pass, "auditor passes a well-formed test");
    is($a->fail_count, 0, "no failures");
    is($a->pass_count, 2, "two passing assertions");

    my $fs = final_of(@out);
    is($fs->{pass}, 1, "final state pass=1");
};

subtest missing_plan_fails => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, assert_f(1, number => 1), exit_f(0));

    ok(!$a->pass, "a test with no plan fails");
};

subtest plan_count_mismatch_fails => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, plan_f(3), assert_f(1, number => 1), exit_f(0));

    ok(!$a->pass, "planned 3 but saw 1 -> fail");
};

subtest failing_assert => sub {
    my $a   = Test2::Harness2::Collector::Auditor->new;
    my @out = run_auditor($a, plan_f(1), assert_f(0, number => 1), exit_f(0));

    ok(!$a->pass, "a failing assertion fails the test");
    ok((grep { $_ eq 'failing' } transitions(@out)), "a failing transition was emitted");
};

subtest amnesty_is_not_failure => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, plan_f(1), assert_f(0, number => 1, amnesty => [{tag => 'TODO', details => 'later'}]), exit_f(0));

    ok($a->pass, "an amnestied (TODO) failure does not fail the test");
};

subtest nonzero_exit_fails => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, plan_f(1), assert_f(1, number => 1), exit_f(256));

    ok(!$a->pass, "a non-zero child exit fails the test");
};

subtest bailout_fails_and_records_halt => sub {
    my $a   = Test2::Harness2::Collector::Auditor->new;
    my @out = run_auditor($a, plan_f(1), assert_f(1, number => 1), {control => {halt => 1, details => 'bail'}}, exit_f(0));

    ok(!$a->pass, "a bail-out fails the test");
    my $fs = final_of(@out);
    is($fs->{halt}, 'bail', "halt reason recorded in final state");
};

subtest duplicate_assertion_number_fails => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, plan_f(2), assert_f(1, number => 1), assert_f(1, number => 1), exit_f(0));

    ok(!$a->pass, "a duplicated assertion number fails the test");
};

subtest missing_assertion_number_fails => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;
    run_auditor($a, plan_f(2), assert_f(1, number => 1), assert_f(1, number => 3), exit_f(0));

    ok(!$a->pass, "a skipped assertion number fails the test");
};

subtest diagnosing_transition => sub {
    my $a   = Test2::Harness2::Collector::Auditor->new;
    my @out = run_auditor($a, plan_f(1), assert_f(1, number => 1), {info => [{tag => 'DIAG', debug => 1, details => 'note'}]}, exit_f(0));

    ok((grep { $_ eq 'diagnosing' } transitions(@out)), "a diagnosing transition was emitted");
    ok($a->pass, "diagnostics alone do not fail the test");
};

subtest buffered_subtest_pass => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;

    my $subtest = {
        assert => {pass => 1, details => 'my subtest', number => 1},
        parent => {
            details  => 'my subtest',
            children => [
                assert_f(1, number => 1, name => 'child a'),
                assert_f(1, number => 2, name => 'child b'),
                plan_f(2),
            ],
        },
        trace => {nested => 0},
    };

    my @out = run_auditor($a, $subtest, plan_f(1), exit_f(0));

    ok($a->pass, "a passing buffered subtest passes");

    my $fs = final_of(@out);
    is(scalar(@{$fs->{subtests}}), 1, "one top-level subtest recorded");
    is($fs->{subtests}[0]{name},       'my subtest', "subtest name captured");
    is($fs->{subtests}[0]{pass},       1,            "subtest marked passing");
    is($fs->{subtests}[0]{count_pass}, 2,            "subtest passing-child count");
};

subtest buffered_subtest_fail => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;

    my $subtest = {
        assert => {pass => 0, details => 'bad subtest', number => 1},
        parent => {
            details  => 'bad subtest',
            children => [
                assert_f(1, number => 1, name => 'child a'),
                assert_f(0, number => 2, name => 'child b'),
                plan_f(2),
            ],
        },
        trace => {nested => 0},
    };

    my @out = run_auditor($a, $subtest, plan_f(1), exit_f(0));

    ok(!$a->pass, "a failing buffered subtest fails the test");

    my $fs = final_of(@out);
    is($fs->{subtests}[0]{pass}, 0, "subtest marked failing");
};

subtest timing_in_final_state => sub {
    my $a = Test2::Harness2::Collector::Auditor->new;

    my @out = map { $a->process_event(ev($_)) } (
        {assert => {pass => 1, number => 1}, trace => {stamp => 10}},
        {plan => {count => 1}, trace => {stamp => 11}},
        {harness_process_exit => {all => 0, err => 0, sig => 0, dmp => 0, start_stamp => 8, stamp => 15}},
    );

    my $fs = final_of(@out);
    ok($fs->{times}, "final state carries phase timings");
    is($fs->{times}{startup}, 2, "startup phase (first 10 - start 8)");
    is($fs->{times}{total},   7, "total phase (stop 15 - start 8)");
};

done_testing;
