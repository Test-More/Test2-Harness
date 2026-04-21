use Test2::V0;

use App::Yath2::Renderer::Formatter;

sub _mk {
    my $o = '';
    my $e = '';
    open(my $ofh, '>', \$o) or die $!;
    open(my $efh, '>', \$e) or die $!;
    return (
        App::Yath2::Renderer::Formatter->new(io => $ofh, io_err => $efh),
        \$o, \$e,
    );
}

subtest 'passing asserts render to STDOUT' => sub {
    my ($r, $o, $e) = _mk();

    $r->event_in({
        event_id   => 'e1',
        stamp      => 0,
        facet_data => {
            plan   => {count => 1},
            assert => {pass => 1, details => 'named pass'},
        },
    });

    like($$o, qr/\[PLAN\s+\] Expected assertions: 1/, 'plan line on stdout');
    like($$o, qr/\[PASS\s+\] named pass/,             'pass line on stdout');
    is($$e, '', 'nothing on stderr');
};

subtest 'failing asserts render to STDERR' => sub {
    my ($r, $o, $e) = _mk();

    $r->event_in({
        event_id   => 'e2',
        stamp      => 0,
        facet_data => {
            assert => {pass => 0, details => 'named fail', no_debug => 1},
        },
    });

    like($$e, qr/\[FAIL\s+\] named fail/, 'FAIL on stderr');
    is($$o, '', 'nothing on stdout for a bare fail');
};

subtest 'info routing by tag' => sub {
    my ($r, $o, $e) = _mk();

    $r->event_in({
        event_id   => 'e3',
        stamp      => 0,
        facet_data => {info => [
            {tag => 'NOTE', details => 'quiet note'},
            {tag => 'DIAG', details => 'loud diag'},
        ]},
    });

    like($$o, qr/\[NOTE\s+\] quiet note/, 'NOTE on stdout');
    like($$e, qr/\[DIAG\s+\] loud diag/,  'DIAG on stderr');
};

subtest 'errors render on STDERR' => sub {
    my ($r, $o, $e) = _mk();

    $r->event_in({
        event_id   => 'e4',
        stamp      => 0,
        facet_data => {errors => [{details => 'boom', fail => 1}]},
    });

    like($$e, qr/\[FATAL\s+\] boom/, 'errors on stderr');
    is($$o, '', 'stdout clean');
};

subtest 'end_of_run emits a result line' => sub {
    my ($r, $o, $e) = _mk();

    $r->end_of_run(run_id => 'r-1', pass_count => 3, fail_count => 0);
    like($$o, qr/\[PASSED\s+\] run r-1: 3 passed, 0 failed/, 'pass goes to stdout');

    my ($r2, $o2, $e2) = _mk();
    $r2->end_of_run(run_id => 'r-2', pass_count => 1, fail_count => 1);
    like($$e2, qr/\[FAILED\s+\] run r-2: 1 passed, 1 failed/, 'fail goes to stderr');
};

subtest 'role composition' => sub {
    ok(
        Role::Tiny::does_role('App::Yath2::Renderer::Formatter', 'App::Yath2::Role::Renderer'),
        'Formatter consumes the renderer role',
    );
};

done_testing;
