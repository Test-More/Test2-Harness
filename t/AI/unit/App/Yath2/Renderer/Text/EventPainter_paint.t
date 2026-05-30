use Test2::V0;
use v5.38;

use App::Yath2::Renderer::Text::EventPainter;

# paint() turns one event (facet_data) into graph lines. No color here.
my $p = App::Yath2::Renderer::Text::EventPainter->new(color => 0);

subtest passing_assert => sub {
    my @lines = $p->paint({assert => {pass => 1, details => 'it works'}});
    is(\@lines, ['*  it works'], "a passing assertion is one '*' node line");
};

subtest failing_assert_with_debug => sub {
    my @lines = $p->paint({
        assert => {pass => 0, details => 'broke'},
        trace  => {frame => ['main', 'foo.t', 42]},
    });
    is(
        \@lines,
        ['X  broke', '!  foo.t line 42'],
        "failure shows an 'X' assert then a '!' debug line",
    );
};

subtest amnesty_assert => sub {
    my @lines = $p->paint({
        assert  => {pass => 0, details => 'todo item'},
        amnesty => [{tag => 'TODO', details => 'later'}],
        trace   => {frame => ['main', 'foo.t', 7]},
    });
    is(\@lines, ['o  todo item'], "amnesty turns the node to 'o' and suppresses debug");
};

subtest note_and_diag_nodes => sub {
    my @note = $p->paint({info => [{tag => 'NOTE', details => 'a note'}]});
    is(\@note, ['|  a note'], "note uses the '|' node");

    my @diag = $p->paint({info => [{tag => 'DIAG', details => 'a diag'}]});
    is(\@diag, ['!  a diag'], "diag uses the '!' node");
};

subtest plan_hidden_unless_verbose => sub {
    my @quiet = $p->paint({plan => {count => 3}}, verbosity => 1);
    is(\@quiet, [], "plan is hidden at verbosity 1");

    my @loud = $p->paint({plan => {count => 3}}, verbosity => 2);
    is(scalar(@loud), 1, "plan shows at verbosity 2");
    like($loud[0], qr/Expected assertions: 3/, "plan text rendered");
};

subtest subtest_branch => sub {
    my @lines = $p->paint({
        assert => {pass => 1, details => 'outer'},
        parent => {children => [
            {assert => {pass => 1, details => 'child a'}},
            {info    => [{tag => 'NOTE', details => 'a note'}]},
        ]},
    });

    is(
        \@lines,
        [
            '*  outer',
            ' \\',
            '  *  child a',
            '  |  a note',
            '  ^',
        ],
        "subtest draws assert, branch, indented children, terminator",
    );
};

subtest nested_subtest_indents_two_each => sub {
    my @lines = $p->paint({
        assert => {pass => 1, details => 'outer'},
        parent => {children => [
            {
                assert => {pass => 1, details => 'inner'},
                parent => {children => [{assert => {pass => 1, details => 'leaf'}}]},
            },
        ]},
    });

    is(
        \@lines,
        [
            '*  outer',
            ' \\',
            '  *  inner',
            '   \\',
            '    *  leaf',
            '    ^',
            '  ^',
        ],
        "each nesting level indents two columns",
    );
};

subtest prefix_and_left_pad => sub {
    my @lines = $p->paint({assert => {pass => 1, details => 'x'}}, left_pad => 2, prefix => 'PFX ');
    is(\@lines, ['PFX   *  x'], "prefix then left_pad spaces then node");
};

subtest overflow_wraps_in_plus_block => sub {
    my @lines = $p->paint({info => [{tag => 'NOTE', details => 'a very long line here'}]}, max_width => 10);
    is(
        \@lines,
        ['+', 'a very long line here', '+'],
        "too-wide content is dumped flush-left between '+' markers",
    );
};

subtest multiline_that_fits_is_graphed => sub {
    my @lines = $p->paint({info => [{tag => 'NOTE', details => "l1\nl2"}]}, max_width => 80);
    is(\@lines, ['|  l1', '|  l2'], "each fitting line of a multi-line message gets its own node");
};

subtest color_wraps_node_and_text => sub {
    my $cp = App::Yath2::Renderer::Text::EventPainter->new(color => 1);
    my ($line) = $cp->paint({assert => {pass => 1, details => 'ok'}});

    like($line, qr/\e\[/, "color mode emits ANSI escapes");

    require Term::ANSIColor;
    is(Term::ANSIColor::colorstrip($line), '*  ok', "stripping color yields the plain line");
};

subtest theme_overrides => sub {
    my $tp = App::Yath2::Renderer::Text::EventPainter->new(
        color      => 0,
        PASS       => {node => 'P'},
        ':DEFAULT' => {node => '.'},
    );

    is([$tp->paint({assert => {pass => 1, details => 'x'}})], ['P  x'], "PASS node overridden");
    is([$tp->paint({info => [{tag => 'WEIRD', details => 'y'}]})], ['.  y'], ":DEFAULT node used for an unknown tag");
};

done_testing;
