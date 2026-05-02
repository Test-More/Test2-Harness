use Test2::V0;

use Test2::Harness2::LogLayout qw/
    run_dir
    run_spec_basename
    run_state_basename
    run_events_basename
    run_test_basename
    services_global_dir
    services_run_dir
    service_global_dir
    service_run_dir
    service_global_basename
    service_run_basename
/;

is(run_dir('R1'),             'runs/R1',             'run dir');
is(run_spec_basename('R1'),   'runs/R1/spec',        'run spec basename');
is(run_state_basename('R1'),  'runs/R1/state',       'run state basename');
is(run_events_basename('R1'), 'runs/R1/events',      'run events basename');

# Phase 4.5: per-job directory, per-try basename. Try 0 and try 1 of
# the same job land in distinct files so retries do not clobber.
is(run_test_basename('R1', 'J1', 0), 'runs/R1/tests/J1/0', 'first try of J1');
is(run_test_basename('R1', 'J1', 1), 'runs/R1/tests/J1/1', 'second try of J1');
is(run_test_basename('R1', 'J1', 2), 'runs/R1/tests/J1/2', 'third try of J1');

is(services_global_dir(), 'services',            'global services dir');
is(services_run_dir('R1'), 'runs/R1/services',   'per-run services dir');
is(service_global_dir('harness'),       'services/harness',         'global service dir');
is(service_run_dir('R1', 'run'),        'runs/R1/services/run',     'per-run service dir');
is(service_global_basename('harness', 'events'), 'services/harness/events',     'global service basename with leaf');
is(service_run_basename('R1', 'run', 'state'),   'runs/R1/services/run/state',  'per-run service basename with leaf');

# Required-arg checks.
like(dies { run_test_basename() },    qr/run_id is required/, 'run_test_basename croaks without run_id');
like(dies { run_test_basename('R') }, qr/job_id is required/, 'run_test_basename croaks without job_id');
like(
    dies { run_test_basename('R', 'J') },
    qr/job_try is required/,
    'run_test_basename croaks without job_try',
);

done_testing;
