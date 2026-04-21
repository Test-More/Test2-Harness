use Test2::V0;

use App::Yath2::Renderer::Summary;

sub _mk {
    my $buf = '';
    open(my $fh, '>', \$buf) or die $!;
    return (App::Yath2::Renderer::Summary->new(io => $fh), \$buf);
}

subtest 'end_of_run prints a summary block' => sub {
    my ($r, $buf) = _mk();

    $r->start_of_run(run_id => 'r-1');
    $r->end_of_run(run_id => 'r-1', pass_count => 3, fail_count => 0, duration => 4.25);

    like($$buf, qr/Summary for run r-1/, 'run_id in header');
    like($$buf, qr/Files Passed:\s*3/,   'files passed count');
    like($$buf, qr/Files Failed:\s*0/,   'files failed count');
    like($$buf, qr/Wall Time:\s*4\.25s/, 'wall-time is formatted');
    like($$buf, qr/RESULT: PASSED/,      'verdict is PASSED');
};

subtest 'fail verdict' => sub {
    my ($r, $buf) = _mk();
    $r->end_of_run(run_id => 'r', pass_count => 1, fail_count => 1);
    like($$buf, qr/RESULT: FAILED/, 'verdict is FAILED');
};

subtest 'jobs list surfaces failing files' => sub {
    my ($r, $buf) = _mk();

    $r->end_of_run(
        run_id     => 'r',
        pass_count => 1,
        fail_count => 2,
        jobs       => [
            {job_id => 'j1', pass => 1, file => 't/a.t'},
            {job_id => 'j2', pass => 0, file => 't/b.t'},
            {job_id => 'j3', pass => 0, file => 't/c.t'},
        ],
    );

    like($$buf, qr/^Failed tests:/m, 'failed tests section appears');
    like($$buf, qr{  - t/b\.t},      'b.t appears');
    like($$buf, qr{  - t/c\.t},      'c.t appears');
    unlike($$buf, qr{t/a\.t}, 'passing a.t is not listed');
};

subtest 'event_in tracks failures when the layer does not supply a jobs list' => sub {
    my ($r, $buf) = _mk();

    $r->event_in({
        event_id   => 'e1',
        stamp      => 0,
        facet_data => {
            harness => {
                job_id             => 'j1',
                file               => 't/a.t',
                test_job_completed => {job_id => 'j1', pass => 0},
            },
        },
    });
    $r->event_in({
        event_id   => 'e2',
        stamp      => 1,
        facet_data => {
            harness => {
                job_id             => 'j2',
                file               => 't/b.t',
                test_job_completed => {job_id => 'j2', pass => 1},
            },
        },
    });

    $r->end_of_run(run_id => 'r', pass_count => 1, fail_count => 1);

    like($$buf, qr{  - t/a\.t}, 'failing t/a.t surfaces without a jobs list');
    unlike($$buf, qr{t/b\.t},    'passing t/b.t is not listed');
};

subtest 'role composition' => sub {
    ok(
        Role::Tiny::does_role('App::Yath2::Renderer::Summary', 'App::Yath2::Role::Renderer'),
        'Summary consumes the renderer role',
    );
};

done_testing;
