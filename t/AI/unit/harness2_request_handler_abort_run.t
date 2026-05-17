use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::RunStates;

# Fake run-state objects that record the latched reason.
{
    package RS;
    sub new            { bless { reason => undef }, shift }
    sub aborted_reason { $_[0]->{reason} }
    sub latch_aborted_reason { $_[0]->{reason} //= $_[1]; return }
}

my $rs1 = RS->new;
my $rs2 = RS->new;

my $svc = bless {
    run_states => Test2::Harness2::RunStates->new(
        run_states => {
            A => $rs1,
            B => $rs2,
        },
    ),
}, 'Test2::Harness2';

# No selectors -> error.
my $res = $svc->request_handler_abort_run({}, undef);
is($res->{ok}, 0, 'no selectors -> ok=0');

# Explicit run_id targets only that run.
$res = $svc->request_handler_abort_run({run_id => 'A'}, undef);
is($res, {ok => 1, aborted => ['A']}, 'aborts run A');
is($rs1->aborted_reason, 'user_abort', 'run A latched');
is($rs2->aborted_reason, undef,         'run B untouched');

# Idempotent: aborting A again returns ok=1 with empty list.
$res = $svc->request_handler_abort_run({run_id => 'A'}, undef);
is($res, {ok => 1, aborted => []}, 'second abort is a no-op');

# all => 1 aborts the remaining run.
$res = $svc->request_handler_abort_run({all => 1}, undef);
is($res, {ok => 1, aborted => ['B']}, 'aborts remaining run via all');
is($rs2->aborted_reason, 'user_abort', 'run B latched');

# Unknown run -> ok=0 with friendly error.
$res = $svc->request_handler_abort_run({run_id => 'NOPE'}, undef);
is($res->{ok}, 0, 'unknown run -> ok=0');

done_testing;
