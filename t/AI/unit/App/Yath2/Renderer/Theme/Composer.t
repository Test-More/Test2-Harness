use Test2::V0;

use App::Yath2::Renderer::Theme::Composer;

my $C = 'App::Yath2::Renderer::Theme::Composer';

subtest 'render facet short-circuits every rendering path' => sub {
    my $f = {
        render => [{facet => 'custom', tag => 'note', details => 'hello'}],
        assert => {pass => 1, details => 'should not render'},
    };

    is(
        $C->render_one_line($f),
        ['custom', 'NOTE', 'hello'],
        'render_one_line picks the first render entry',
    );
    is(
        $C->render_verbose($f),
        [['custom', 'NOTE', 'hello']],
        'render_verbose includes every render entry',
    );
};

subtest 'render_one_line priorities' => sub {
    is(
        $C->render_one_line({control => {halt => 1, details => 'bail out'}}),
        ['control', 'HALT', 'bail out'],
        'control halt wins over nothing else',
    );
    is(
        $C->render_one_line({assert => {pass => 1, details => 'ok 1'}}),
        ['assert', 'PASS', 'ok 1'],
        'a passing assert renders as PASS',
    );
    is(
        $C->render_one_line({assert => {pass => 0, details => 'ok 2'}}),
        ['assert', 'FAIL', 'ok 2'],
        'a failing assert renders as FAIL',
    );
    is(
        $C->render_one_line({
            assert  => {pass => 0, details => 'amnesty hit'},
            amnesty => [{tag => 'TODO', details => 'not yet'}],
        }),
        ['assert', '! PASS !', 'amnesty hit'],
        'amnestied failure renders as ! PASS !',
    );
};

subtest 'render_verbose composition' => sub {
    my $f = {
        plan    => {count => 3},
        assert  => {pass => 1, details => 'asserted'},
        info    => [{tag => 'NOTE', details => 'a note'}],
        errors  => [{tag => 'ERR',  details => 'fell over'}],
    };

    is(
        $C->render_verbose($f),
        [
            ['plan',   'PLAN',  'Expected assertions: 3'],
            ['assert', 'PASS',  'asserted'],
            ['info',   'NOTE',  'a note'],
            ['error',  'ERR',   'fell over'],
        ],
        'verbose walks the plan/assert/info/errors pipeline',
    );
};

subtest 'render_brief filters to the important bits' => sub {
    my $f = {
        assert => {pass => 0, details => 'red'},
        trace  => {frame => ['Foo', 't/x.t', 42]},
        info   => [
            {tag => 'NOTE', details => 'chatty',   debug => 0, important => 0, peek => 0},
            {tag => 'DIAG', details => 'loud',     debug => 1},
        ],
    };

    my $b = $C->render_brief($f);
    is(
        $b,
        [
            ['assert', 'FAIL',  'red'],
            ['trace',  'DEBUG', 't/x.t line 42'],
            ['info',   'DIAG',  'loud'],
        ],
        'brief keeps the failure, debug info, and trace',
    );
};

subtest 'render_plan SKIP variants' => sub {
    is(
        $C->render_plan({plan => {skip => 1, details => 'no net'}}),
        ['plan', 'SKIP ALL', 'no net'],
        'skip with reason uses the reason',
    );
    is(
        $C->render_plan({plan => {skip => 1}}),
        ['plan', 'SKIP ALL', 'No reason given'],
        'skip without reason falls back',
    );
    is(
        $C->render_plan({plan => {none => 1, details => 'no plan declared'}}),
        ['plan', 'NO  PLAN', 'no plan declared'],
        'no-plan carries details through',
    );
};

subtest 'render_amnesty deduplicates on tag+details' => sub {
    my @out = $C->render_amnesty({
        amnesty => [
            {tag => 'TODO', details => 'x'},
            {tag => 'TODO', details => 'x'},
            {tag => 'TODO', details => 'y'},
        ],
    });
    is(scalar(@out), 2, 'duplicate entries collapse');
};

subtest 'render_debug' => sub {
    is(
        $C->render_debug({trace => {details => 'deep trace'}}),
        ['trace', 'DEBUG', 'deep trace'],
        'trace details win when present',
    );
    is(
        $C->render_debug({trace => {frame => ['Foo', 't/x.t', 7]}}),
        ['trace', 'DEBUG', 't/x.t line 7'],
        'frame fallback builds file-line',
    );
    is(
        $C->render_debug({}),
        ['trace', 'DEBUG', '[No trace info available]'],
        'no trace data surfaces the sentinel',
    );
};

subtest 'render_errors tag fallback' => sub {
    is(
        [$C->render_errors({errors => [{details => 'exploded', fail => 1}]})],
        [['error', 'FATAL', 'exploded']],
        'fail without tag becomes FATAL',
    );
    is(
        [$C->render_errors({errors => [{details => 'warned'}]})],
        [['error', 'ERROR', 'warned']],
        'plain error without tag becomes ERROR',
    );
};

subtest 'render_control super_verbose' => sub {
    my $f = {control => {encoding => 'UTF-8', details => 'encoding updated'}};
    is(
        [$C->render_control($f, super_verbose => 1)],
        [['control', 'ENCODING', 'UTF-8']],
        'super_verbose surfaces encoding',
    );
    is(
        [$C->render_control($f)],
        [],
        'default render_control drops non-halt control facets',
    );
};

done_testing;
