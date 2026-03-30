use Test2::V0 -target => 'Test2::Harness::Run';
use Test2::Util::UUID qw/gen_uuid/;

sub make_run {
    return $CLASS->new(
        run_id         => gen_uuid(),
        test_settings  => {class => 'Test2::Harness::TestSettings'},
        aggregator_ipc => {protocol => 'Test2::Harness::IPC::Protocol::AtomicPipe', connect => []},
        @_,
    );
}

subtest 'required attributes' => sub {
    like(
        dies {
            $CLASS->new(
                test_settings  => {class => 'Test2::Harness::TestSettings'},
                aggregator_ipc => {protocol => 'Test2::Harness::IPC::Protocol::AtomicPipe', connect => []},
            )
        },
        qr/run_id.*required/i,
        'run_id is required',
    );

    like(
        dies {
            $CLASS->new(
                run_id         => gen_uuid(),
                aggregator_ipc => {protocol => 'Test2::Harness::IPC::Protocol::AtomicPipe', connect => []},
            )
        },
        qr/test_settings.*required/i,
        'test_settings is required',
    );

    like(
        dies {
            $CLASS->new(
                run_id        => gen_uuid(),
                test_settings => {class => 'Test2::Harness::TestSettings'},
            )
        },
        qr/aggregator_ipc.*aggregator_use_io/i,
        'aggregator_ipc or aggregator_use_io is required',
    );
};

subtest 'basic construction' => sub {
    my $run = make_run();
    ok($run->isa($CLASS), 'creates instance');
    ok($run->run_id, 'run_id accessor returns value');
    ok($run->test_settings->isa('Test2::Harness::TestSettings'), 'test_settings inflated');
};

subtest 'aggregator_use_io as alternative to aggregator_ipc' => sub {
    my $run = $CLASS->new(
        run_id            => gen_uuid(),
        test_settings     => {class => 'Test2::Harness::TestSettings'},
        aggregator_use_io => 1,
    );
    ok($run->isa($CLASS), 'constructs with aggregator_use_io');
};

subtest 'set_ipc and ipc' => sub {
    my $run = make_run();
    my $fake_ipc = bless {}, 'FakeIPC';
    $run->set_ipc($fake_ipc);
    is($run->ipc, $fake_ipc, 'set_ipc/ipc round-trip');
};

subtest 'abort_on_bail attribute' => sub {
    my $run = make_run();
    # Default - not set in constructor, accessor returns undef or default
    my $run2 = make_run(abort_on_bail => 1);
    is($run2->abort_on_bail, 1, 'abort_on_bail set to 1');
};

subtest 'TO_JSON excludes internal fields' => sub {
    my $run = make_run();
    my $fake_ipc = bless {}, 'FakeIPC';
    $run->set_ipc($fake_ipc);

    my $json = $run->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns hashref');
    ok(!exists($json->{ipc}),           'TO_JSON excludes ipc');
    ok(!exists($json->{connect}),       'TO_JSON excludes connect');
    ok(!exists($json->{send_event_cb}), 'TO_JSON excludes send_event_cb');
    ok(exists($json->{run_id}),         'TO_JSON includes run_id');
};

subtest 'data_no_jobs excludes jobs and job_lookup' => sub {
    my $run = make_run();
    my $data = $run->data_no_jobs;
    ref_ok($data, 'HASH', 'data_no_jobs returns hashref');
    ok(!exists($data->{jobs}),       'data_no_jobs excludes jobs');
    ok(!exists($data->{job_lookup}), 'data_no_jobs excludes job_lookup');
};

done_testing;
