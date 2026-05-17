use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::RunStates;

# Slot constants exposed by Object::HashBase so the test can verify the
# raw structure when needed.
use constant RUN_STATES_SLOT      => Test2::Harness2::RunStates::RUN_STATES();
use constant RUN_FLAGS_SLOT       => Test2::Harness2::RunStates::RUN_FLAGS();
use constant COMPLETED_RUNS_SLOT  => Test2::Harness2::RunStates::COMPLETED_RUNS();
use constant RUN_ORD_COUNTER_SLOT => Test2::Harness2::RunStates::RUN_ORD_COUNTER();

subtest defaults_populate_slots => sub {
    my $rs = Test2::Harness2::RunStates->new;
    is($rs->{+RUN_STATES_SLOT},      {}, 'run_states defaults to empty hash');
    is($rs->{+RUN_FLAGS_SLOT},       {}, 'run_flags defaults to empty hash');
    is($rs->{+COMPLETED_RUNS_SLOT},  {}, 'completed_runs defaults to empty hash');
    is($rs->{+RUN_ORD_COUNTER_SLOT}, 0,  'run_ord_counter defaults to 0');
};

subtest ctor_seeded_values_win => sub {
    my $rs = Test2::Harness2::RunStates->new(
        run_states      => {r1 => 'state-1'},
        run_flags       => {r1 => {pass => 0}},
        completed_runs  => {r9 => {pass => 1}},
        run_ord_counter => 42,
    );
    is($rs->state('r1'),     'state-1',     'pre-seeded state visible');
    is($rs->flags('r1'),     {pass => 0},   'pre-seeded flags visible');
    is($rs->completed('r9'), {pass => 1},   'pre-seeded completed visible');
    is($rs->next_ord, 42, 'pre-seeded counter starts where set');
    is($rs->next_ord, 43, 'counter keeps incrementing from the seed');
};

subtest state_roundtrip => sub {
    my $rs = Test2::Harness2::RunStates->new;

    is($rs->state('nope'), undef, 'lookup of missing run returns undef');

    $rs->set_state('r-1', {hello => 'world'});
    is($rs->state('r-1'), {hello => 'world'}, 'state returns set value');

    is([sort $rs->all_run_ids], ['r-1'], 'all_run_ids reflects set');

    $rs->set_state('r-2', {x => 1});
    is([sort $rs->all_run_ids], ['r-1', 'r-2'], 'second state visible too');

    my $dropped = $rs->delete_state('r-1');
    is($dropped, {hello => 'world'}, 'delete_state returns dropped value');
    is($rs->state('r-1'), undef, 'state gone after delete');
    is([sort $rs->all_run_ids], ['r-2'], 'all_run_ids no longer includes deleted run');

    is($rs->delete_state('never'), undef, 'delete on missing run is undef');
};

subtest flags_lazy_init => sub {
    my $rs = Test2::Harness2::RunStates->new;

    is($rs->flags_peek('r-3'), undef, 'flags_peek does NOT initialize');

    my $f = $rs->flags('r-3');
    is(
        $f,
        {
            completed_job_ids    => {},
            completed_job_states => {},
            failing_emitted      => 0,
            pass                 => 1,
        },
        'flags returns canonical default shape on lazy init',
    );

    # Mutation visible across subsequent calls (same hashref returned).
    $f->{failing_emitted} = 1;
    is($rs->flags('r-3')->{failing_emitted}, 1, 'flags returns the same ref so mutation sticks');
    is($rs->flags_peek('r-3')->{failing_emitted}, 1, 'flags_peek returns the same ref after init');
};

subtest delete_flags_drops_entry => sub {
    my $rs = Test2::Harness2::RunStates->new;
    $rs->flags('r-4')->{custom} = 1;
    ok($rs->flags_peek('r-4'), 'flags exist before delete');

    my $dropped = $rs->delete_flags('r-4');
    is($dropped->{custom}, 1, 'delete_flags returns dropped hash');
    is($rs->flags_peek('r-4'), undef, 'flags gone after delete');

    is($rs->delete_flags('never'), undef, 'delete on missing flags is undef');
};

subtest clear_flags_wipes_everything => sub {
    my $rs = Test2::Harness2::RunStates->new;
    $rs->flags('r-a')->{x} = 1;
    $rs->flags('r-b')->{x} = 2;
    is([sort keys %{$rs->{+RUN_FLAGS_SLOT}}], ['r-a', 'r-b'], 'two flag entries before clear');

    $rs->clear_flags;
    is($rs->{+RUN_FLAGS_SLOT}, {}, 'all flags gone after clear_flags');
};

subtest completed_roundtrip => sub {
    my $rs = Test2::Harness2::RunStates->new;

    is($rs->completed('r-5'), undef, 'no completed entry yet');

    my $payload = {pass => 1, results => {j => 1}};
    $rs->record_completed('r-5', $payload);
    is($rs->completed('r-5'), $payload, 'completed entry round-trips');

    $rs->record_completed('r-6', {pass => 0});
    is(
        [sort $rs->all_completed_ids],
        ['r-5', 'r-6'],
        'all_completed_ids reflects both',
    );
};

subtest next_ord_increments => sub {
    my $rs = Test2::Harness2::RunStates->new;
    is($rs->next_ord, 0, 'first allocation is 0');
    is($rs->next_ord, 1, 'second allocation is 1');
    is($rs->next_ord, 2, 'third allocation is 2');

    my $rs2 = Test2::Harness2::RunStates->new(run_ord_counter => 100);
    is($rs2->next_ord, 100, 'seeded counter returns seed first');
    is($rs2->next_ord, 101, 'then increments from there');
};

subtest delete_state_and_flags_together => sub {
    my $rs = Test2::Harness2::RunStates->new;
    $rs->set_state('r-7', 'state');
    $rs->flags('r-7')->{pass} = 0;
    $rs->record_completed('r-7', {pass => 0});

    $rs->delete_state('r-7');
    $rs->delete_flags('r-7');

    is($rs->state('r-7'),    undef, 'state cleared');
    is($rs->flags_peek('r-7'), undef, 'flags cleared');
    # Completed is intentionally NOT cleared by delete_state/delete_flags:
    # the harness's finalize path keeps the COMPLETED_RUNS entry alive
    # so request_handler_run_results can still answer.
    is($rs->completed('r-7'), {pass => 0}, 'completed snapshot retained');
};

done_testing;
