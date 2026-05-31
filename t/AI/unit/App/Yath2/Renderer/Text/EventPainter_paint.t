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

subtest stray_event_uses_arrow_node_at_left_pad => sub {
    # Strays keep the caller's left_pad but get no subtest indentation, and are
    # never expanded as a subtest even if they carry a parent facet.
    my @at_zero = $p->paint({harness_auditor => {stray => 1}, assert => {pass => 1, details => 'rt'}});
    is(\@at_zero, ['>  rt'], "stray uses '>' at the default left_pad 0");

    my @at_two = $p->paint(
        {
            harness_auditor => {stray => 1},
            assert          => {pass => 1, details => 'rt'},
            parent          => {children => [{assert => {pass => 1, details => 'child'}}]},
        },
        left_pad => 2,
    );
    is(\@at_two, ['  >  rt'], "stray honors left_pad and is not expanded");
};

subtest stray_event_is_dark_grey => sub {
    my $cp = App::Yath2::Renderer::Text::EventPainter->new(color => 1);
    my ($line) = $cp->paint({harness_auditor => {stray => 1}, info => [{tag => 'NOTE', details => 'n'}]});

    require Term::ANSIColor;
    my $grey = Term::ANSIColor::color('bright_black');
    like($line, qr/\Q$grey\E/, "stray painted dark grey (bright_black)");
    is(Term::ANSIColor::colorstrip($line), '>  n', "plain form is '>' node");
};

subtest tags_prefix_each_line => sub {
    # Tag is centered in an 8-wide field in square brackets; left_pad defaults to
    # 2 when tags are on. Markers get a blank tag so columns align.
    my @lines = $p->paint(
        {
            assert => {pass => 1, details => 'outer'},
            parent => {children => [{info => [{tag => 'DIAG', details => 'd'}]}]},
        },
        tags => 1,
    );

    is(
        \@lines,
        [
            '[  PASS  ]  *  outer',
            (' ' x 13) . '\\',          # marker tag column is spaces, no brackets
            '[  DIAG  ]    !  d',
            (' ' x 14) . '^',
        ],
        "each line gets a centered [TAG]; left_pad defaults to 2; markers blank-spaced",
    );
};

subtest tags_default_left_pad => sub {
    my @with    = $p->paint({assert => {pass => 1, details => 'x'}}, tags => 1);
    my @without = $p->paint({assert => {pass => 1, details => 'x'}});
    is(\@with,    ['[  PASS  ]  *  x'], "tags on: left_pad defaults to 2");
    is(\@without, ['*  x'],             "tags off: no tag column, left_pad 0");
};

subtest tags_long_tag_truncated => sub {
    my @lines = $p->paint({info => [{tag => 'SUPERLONGTAG', details => 'x'}]}, tags => 1);
    # 12-char tag truncated to 8.
    is(\@lines, ['[SUPERLON]  |  x'], "an over-long tag is truncated to the field width");
};

subtest tags_colored => sub {
    my $cp = App::Yath2::Renderer::Text::EventPainter->new(color => 1);
    my ($line) = $cp->paint({assert => {pass => 1, details => 'ok'}}, tags => 1);

    require Term::ANSIColor;
    my $white = Term::ANSIColor::color('bold bright_white');
    my $green = Term::ANSIColor::color('green');
    like($line, qr/\Q$white\E\[/,        "brackets are white");
    like($line, qr/\Q$green\E\s*PASS/,   "tag text takes the node color");
    is(Term::ANSIColor::colorstrip($line), '[  PASS  ]  *  ok', "plain form is the bracketed tag line");
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
