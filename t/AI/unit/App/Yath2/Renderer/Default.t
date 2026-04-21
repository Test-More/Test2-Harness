use Test2::V0;

use App::Yath2::Renderer::Default;

sub _mk_renderer {
    my $buf = '';
    open(my $fh, '>', \$buf) or die $!;
    my $r = App::Yath2::Renderer::Default->new(io => $fh);
    return ($r, \$buf);
}

subtest 'start_of_run / end_of_run bracket the stream' => sub {
    my ($r, $bufref) = _mk_renderer();

    $r->start_of_run(run_id => 'r-1');
    $r->event_in({
        event_id   => 'e-1',
        stamp      => 1000,
        facet_data => {assert => {pass => 1, details => 'ok 1'}},
    });
    $r->end_of_run(run_id => 'r-1', pass_count => 1, fail_count => 0);

    like($$bufref, qr/^\[RUN\s+\] r-1: starting run/m, 'start_of_run header');
    like($$bufref, qr/^\[PASSED\s*\] r-1: run complete: 1 passed, 0 failed/m, 'end_of_run summary');
};

subtest 'event_in renders an assert via the composer' => sub {
    my ($r, $bufref) = _mk_renderer();

    $r->event_in({
        event_id   => 'e-2',
        stamp      => 1001,
        facet_data => {assert => {pass => 0, details => 'named fail'}},
    });

    like($$bufref, qr/\[FAIL\s+\].*named fail/, 'FAIL asserts are emitted (via render_brief)');
};

subtest 'harness lifecycle events take the short path' => sub {
    my ($r, $bufref) = _mk_renderer();

    $r->event_in({
        event_id   => 'e-3',
        stamp      => 2000,
        facet_data => {
            harness => {
                job_id          => 'job-123',
                test_job_started => {job_id => 'job-123'},
                file            => '/abs/path/t/foo.t',
            },
        },
    });
    $r->event_in({
        event_id   => 'e-4',
        stamp      => 2001,
        facet_data => {
            harness => {
                job_id            => 'job-123',
                test_job_completed => {job_id => 'job-123', pass => 1},
                file              => '/abs/path/t/foo.t',
            },
        },
    });

    like($$bufref, qr/^\[LAUNCH\s*\] foo\.t: test started/m, 'test_job_started produces LAUNCH line');
    like($$bufref, qr/^\[PASSED\s*\] foo\.t: test complete/m, 'test_job_completed produces PASSED line');
};

subtest 'job_loggers tracks output files but does not print' => sub {
    my ($r, $bufref) = _mk_renderer();

    $r->event_in({
        event_id   => 'e-5',
        stamp      => 3000,
        facet_data => {
            harness => {
                job_id      => 'job-7',
                job_loggers => {job_id => 'job-7'},
                loggers     => {
                    'Logger::JSONL' => [{output_file => '/tmp/job-7/0.jsonl'}],
                },
            },
        },
    });

    is($$bufref, '', 'job_loggers does not print by default');
    is(
        $r->{job_file_map}->{'job-7'},
        ['/tmp/job-7/0.jsonl'],
        'job_loggers populates the per-job file map',
    );
};

subtest 'role composition' => sub {
    ok(
        Role::Tiny::does_role('App::Yath2::Renderer::Default', 'App::Yath2::Role::Renderer'),
        'Default consumes the renderer role',
    );
};

done_testing;
