use Test2::Bundle::Extended -target => 'Test2::Harness::Renderer::EventStream';
use PerlIO;
use Test2::Harness::Fact;
use Test2::Harness::Result;

can_ok $CLASS => qw{
    color verbose jobs slots parallel clear out_std watch colors graph_colors
    counter
};

subtest init => sub {
    my $one = $CLASS->new;
    isa_ok($one, $CLASS);

    is($one->jobs, {}, "initialized jobs hash");
    is($one->slots, [], "initialized slots array");
    is($one->clear, 0, "clear is set to 0");

    ok($one->out_std, "Populated out_std");

    ok($one->colors, "Got colors");
    ok($one->graph_colors, "Got graph colors");

    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    $one = $CLASS->new(out_std => $fh);
    ok(!$one->color, "no color when fh is not a term");
    ok(!$one->watch, "no watch when fh is not a term");

    $one = $CLASS->new(out_std => $fh, color => 1, watch => 1);
    ok($one->color, "color override");
    ok($one->watch, "watch override");

    return unless eval { require IO::Pty; 1 };
    $fh = IO::Pty->new;
    $one = $CLASS->new(out_std => $fh);
    ok($one->color, "color when fh is a term");
    ok($one->watch, "watch when fh is a term");
};

subtest paint => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    my $one = $CLASS->new(
        out_std => $fh,
        colors => {foo => 'color_foo', bar => 'color_bar', reset => 'color_reset'},
        graph_colors => [qw/color_a color_b color_c/],
    );
    $one->set_jobs({
        0 => { slot => 0 },
        1 => { slot => 1 },
        2 => { slot => 2 },
        3 => { slot => 0 },
    });

    $one->paint(
        'foo bar ',
        [ '0', 'a' ], ' ',
        [ '1', 'b' ], ' ',
        [ '2', 'c' ], ' ',
        [ '3', 'd' ], ' ',
        [ 'foo', 'foo ', 0 ],
        [ 'xxx', 'xxx' ],
        "\n",
    );

    is(
        $foo,
        "foo bar color_aacolor_reset color_bbcolor_reset color_cccolor_reset color_adcolor_reset color_foofoo xxxcolor_reset\n",
        "Painted string"
    );

    $one->set_clear(1);
    $one->paint(
        'foo bar ',
        [ '0', 'a' ], ' ',
        [ '1', 'b' ], ' ',
        [ '2', 'c' ], ' ',
        [ '3', 'd' ], ' ',
        [ 'foo', 'foo ', 0 ],
        [ 'xxx', 'xxx' ],
        "\n",
    );
    ok(!$one->clear, "unset clear");

    is(
        $foo,
        "foo bar color_aacolor_reset color_bbcolor_reset color_cccolor_reset color_adcolor_reset color_foofoo xxxcolor_reset\n" .
        "\e[K" .
        "foo bar color_aacolor_reset color_bbcolor_reset color_cccolor_reset color_adcolor_reset color_foofoo xxxcolor_reset\n",
        "Painted string with clear"
    );
};

subtest encoding => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";

    my $layers = { map {$_ => 1} PerlIO::get_layers($fh) };
    ok(!$layers->{utf8}, "utf8 is off");

    my $one = $CLASS->new(out_std => $fh);
    $one->encoding('utf8');

    $layers = { map {$_ => 1} PerlIO::get_layers($fh) };
    ok($layers->{utf8}, "utf8 is on now");
};

subtest summary => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    my $one = $CLASS->new(
        out_std => $fh,
        colors => {failed => '[failed]', passed => '[passed]', reset => '[reset]'},
    );

    my $pass = mock {passed => 1, name => 'a passing result'};
    my $fail = mock {passed => 0, name => 'a failing result'};

    $one->summary([$pass, $pass, $pass]);
    is($foo, "\n[passed]=== ALL TESTS SUCCEEDED ===\n[reset]\n", "All pass");

    $foo = '';
    open($fh, '>', \$foo) or die "$!";
    $one = $CLASS->new(
        out_std => $fh,
        colors => {failed => '[failed]', passed => '[passed]', reset => '[reset]'},
    );
    $one->summary([$pass, $fail, $pass, $fail, $pass]);
    is($foo, "\n[failed]=== FAILURE SUMMARY ===\n * a failing result\n * a failing result\n[reset]\n", "List failures");
};

subtest listen => sub {
    my $m = mock $CLASS => sub {
        mock override => (
            process => sub { return ("process", @_) },
        );
    };

    my $one = $CLASS->new();
    my $l = $one->listen;
    ref_ok($l, 'CODE', "Got a coderef");
    my @out = $l->('foo', 'bar');
    is(
        \@out,
        ['process', $one, qw/foo bar/],
        "Called process"
    );
};

subtest job_management => sub {
    my $one = $CLASS->new();

    $one->init_job(5);
    like(
        $one,
        object {
            call jobs  => {5 => { slot => 0 }};
            call slots => [5];
        },
        "Added job"
    );

    $one->init_job(3);
    like(
        $one,
        object {
            call jobs  => {5 => { slot => 0 }, 3 => { slot => 1 }};
            call slots => [5,3];
        },
        "Added another job"
    );

    $one->end_job(3);
    like(
        $one,
        object {
            call jobs  => {5 => { slot => 0 }};
            call slots => [5, undef]; # Undef is intentional, preserve ordering
        },
        "Ended job"
    );

    $one->end_job(5);
    like(
        $one,
        object {
            call jobs  => {};
            call slots => [undef, undef]; # The undef's are intentional
        },
        "removed another job"
    );
};

subtest verbose_tag => sub {
    my $one = $CLASS->new(verbose => 1);

    is(
        [$one->_tag(mock {hide => 1})],
        [],
        "Do not show hidden facts"
    );

    is(
        [$one->_tag(mock {start => 1})],
        [qw/LAUNCH file/],
        "start fact"
    );

    is(
        [$one->_tag(mock {parser_select => 1})],
        [qw/PARSER parser_select/],
        "parser selection"
    );

    is(
        [$one->_tag(mock {event => 1, causes_fail => 1})],
        ['NOT OK', 'fail'],
        "failure (not ok)"
    );

    is(
        [$one->_tag(mock {event => 1, increments_count => 1})],
        ['  OK  ', 'pass'],
        "pass (ok)"
    );

    is(
        [$one->_tag(mock {event => {reason => 'xxx'}, increments_count => 1})],
        ['  OK  ', 'skip'],
        "pass (skip)"
    );

    is(
        [$one->_tag(mock {event => {todo => 'xxx'}, increments_count => 1})],
        ['NOT OK', 'todo'],
        "effective pass (todo)"
    );

    is(
        [$one->_tag(mock {event => 1, sets_plan => 1})],
        [' PLAN ', 'plan'],
        "set plan"
    );

    is(
        [$one->_tag(mock {event => 1, summary => " "})],
        [],
        "Nothing to display"
    );

    is(
        [$one->_tag(mock {event => 1, summary => "xxx"})],
        [' NOTE ', 'note'],
        "Note"
    );

    is(
        [$one->_tag(mock {event => 1, summary => "xxx", diagnostics => 1})],
        [' DIAG ', 'diag'],
        "Diag"
    );

    is(
        [$one->_tag(mock {result => 1, causes_fail => 1})],
        ['FAILED', 'failed'],
        "Subtest failure"
    );

    is(
        [$one->_tag(mock {nested => -1, result => mock {plans => [mock {sets_plan => [0, 'skip', 'foo']}]}})],
        ['SKIP!!', 'skipall'],
        "Skipall"
    );

    is(
        [$one->_tag(mock {nested => 1, result => mock { plans => [] }})],
        ['PASSED', 'passed'],
        "Subtest Success"
    );

    is(
        [$one->_tag(mock {encoding => 'utf8'})],
        ['ENCODE', 'encoding'],
        "Encoding event"
    );

    is(
        [$one->_tag(mock {output => "xyz", parsed_from_handle => 'STDERR'})],
        ['STDERR', 'stderr'],
        "random stderr"
    );

    is(
        [$one->_tag(mock {output => "xyz", diagnostics => 1})],
        [' DIAG ', 'diag'],
        "random stderr diag"
    );

    is(
        [$one->_tag(mock {output => "xyz"})],
        ['STDOUT', 'stdout'],
        "random stdout message"
    );

    is(
        [$one->_tag(mock {parse_error => "xyz"})],
        ['PARSER', 'parser'],
        "Parse error"
    );

    is(
        [$one->_tag(mock {parse_error => "xyz", diagnostics => 1})],
        ['PARSER', 'parser'],
        "Parse error + diag"
    );

    is(
        [$one->_tag(mock {})],
        [' ???? ', 'unknown'],
        "unknown"
    );
};

subtest quiet_tag => sub {
    my $one = $CLASS->new(verbose => 0);

    is(
        [$one->_tag(mock {hide => 1})],
        [],
        "Do not show hidden facts"
    );

    is(
        [$one->_tag(mock {start => 1})],
        [qw/LAUNCH file/],
        "start fact"
    );

    is(
        [$one->_tag(mock {parser_select => 1})],
        [],
        "parser selection"
    );

    is(
        [$one->_tag(mock {event => 1, causes_fail => 1})],
        ['NOT OK', 'fail'],
        "failure (not ok)"
    );

    is(
        [$one->_tag(mock {event => 1, increments_count => 1})],
        [],
        "pass (ok)"
    );

    is(
        [$one->_tag(mock {event => {reason => 'xxx'}, increments_count => 1})],
        [],
        "pass (skip)"
    );

    is(
        [$one->_tag(mock {event => {todo => 'xxx'}, increments_count => 1})],
        [],
        "effective pass (todo)"
    );

    is(
        [$one->_tag(mock {event => 1, sets_plan => 1})],
        [],
        "set plan"
    );

    is(
        [$one->_tag(mock {event => 1, summary => " "})],
        [],
        "Nothing to display"
    );

    is(
        [$one->_tag(mock {event => 1, summary => "xxx"})],
        [],
        "Note"
    );

    is(
        [$one->_tag(mock {event => 1, summary => "xxx", diagnostics => 1})],
        [' DIAG ', 'diag'],
        "Diag"
    );

    is(
        [$one->_tag(mock {result => 1, causes_fail => 1})],
        ['FAILED', 'failed'],
        "Subtest failure"
    );

    is(
        [$one->_tag(mock {nested => -1, result => mock {plans => [mock {sets_plan => [0, 'skip', 'foo']}]}})],
        ["SKIP!!", 'skipall'],
        "Skipall"
    );

    is(
        [$one->_tag(mock {nested => -1, result => mock { plans => [] }})],
        ['PASSED', 'passed'],
        "Subtest Success"
    );

    is(
        [$one->_tag(mock {nested => 0, result => mock { plans => [] }})],
        [],
        "Subtest Success nested"
    );

    is(
        [$one->_tag(mock {nested => 1, result => mock { plans => [] }})],
        [],
        "Subtest Success nested"
    );

    is(
        [$one->_tag(mock {encoding => 'utf8'})],
        [],
        "Encoding event"
    );

    is(
        [$one->_tag(mock {output => "xyz", parsed_from_handle => 'STDERR'})],
        ['STDERR', 'stderr'],
        "random stderr"
    );

    is(
        [$one->_tag(mock {output => "xyz", diagnostics => 1})],
        [' DIAG ', 'diag'],
        "random stderr diag"
    );

    is(
        [$one->_tag(mock {output => "xyz"})],
        [],
        "random stdout message"
    );

    is(
        [$one->_tag(mock {parse_error => "xyz"})],
        [],
        "Parse error"
    );

    is(
        [$one->_tag(mock {parse_error => "xyz", diagnostics => 1})],
        ['PARSER', 'parser'],
        "Parse error + diag"
    );

    is(
        [$one->_tag(mock {})],
        [],
        "unknown"
    );
};

subtest tag => sub {
    my $one = $CLASS->new(verbose => 1);

    is(
        [$one->tag(mock {event => 1, causes_fail => 1})],
        [['tag', '['], ['fail', 'NOT OK'], ['tag', ']']],
        "failure (not ok)"
    );

    is(
        [$one->tag(mock {event => 1, increments_count => 1})],
        [['tag', '['], ['pass', '  OK  '], ['tag', ']']],
        "pass (ok)"
    );

    $one = $CLASS->new(verbose => 0);

    is(
        [$one->tag(mock {event => 1, causes_fail => 1})],
        [['tag', '['], ['fail', 'NOT OK'], ['tag', ']']],
        "failure (not ok)"
    );

    is(
        [$one->tag(mock {event => 1, increments_count => 1})],
        [],
        "pass (ok) (non-verbose)"
    );
};

subtest do_watch => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    my $one = $CLASS->new(
        out_std => $fh,
        verbose => 0,
        watch   => 0,
        clear   => 0,
    );

    $one->do_watch;
    ok(!$foo, "nothing painted");
    is($one->clear, 0, "clear unset");

    $one->set_verbose(1);
    $one->do_watch;
    ok(!$foo, "nothing painted");
    is($one->clear, 0, "clear unset");

    $one->set_watch(1);
    $one->do_watch;
    ok(!$foo, "nothing painted");
    is($one->clear, 0, "clear unset");

    $one->set_verbose(0);
    $one->do_watch;
    is($one->clear, 1, "clear set");
    is($foo, " Events Seen: 0\r", "Painted ticker");
};

subtest tree => sub {
    my $one = $CLASS->new();
    $one->set_slots([2, undef, 5, 3]);
    $one->set_jobs(
        {
            2 => {counter => 5},
            3 => {counter => 2},
            5 => {counter => 1},
        }
    );

    is(
        [$one->tree(2)],
        [[2, '|'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree"
    );

    is(
        [$one->tree(2, mock {})],
        [[2, '+'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with mark"
    );

    is(
        [$one->tree(2, mock {start => 1})],
        [['mark', '_'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with start mark"
    );

    is(
        [$one->tree(2, mock {result => 1, nested => -1})],
        [['mark', '='], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with result mark"
    );

    is(
        [$one->tree(2, mock {result => 1, nested => 1})],
        [[2, '+'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "nested result"
    );

    is(
        [$one->tree(5, mock {})],
        [['2', '|'], ' ', ' ', ' ', [5, '+'], ' ', [3, '|']],
        "Mark for counter < 1"
    );
};

subtest painted_length => sub {
    is(
        $CLASS->painted_length([1, 'a'], 'xyz', [2, 'b']),
        5,
        "Just the length of the text, not colors"
    );
};

subtest fact_summary => sub {
    my $one = $CLASS->new();
    local $ENV{T2_TERM_SIZE} = 80;

    is(
        [$one->fact_summary(mock({summary => 'xyz', start => 1}), ["abc"])],
        [[['file', 'xyz']], []],
        "Got summary"
    );

    is(
        [$one->fact_summary(mock({summary => "abc\ndef\nghi", start => 1}), ["abc"])],
        [
            [
                ['file', "abc"],
                ['file', "def"],
                ['file', "ghi"],
            ],
            []
        ],
        "Multi-line summary"
    );

    is(
        [$one->fact_summary(mock({summary => ("aaa" x 100), start => 1}), ["abc"])],
        [
            [
                ['blob', '----- START -----'],
            ],
            [
                ['file', "aaa" x 100],
                "\n",
                "abc",
                ['blob', '------ END ------'],
                "\n"
            ]
        ],
        "long summary"
    );

};

subtest render => sub {
    my $one = $CLASS->new();
    local $ENV{T2_TERM_SIZE} = 80;

    my (@tag, @tree, @summary);
    my $m = mock $CLASS => sub {
        mock override => (tag          => sub { @tag });
        mock override => (tree         => sub { @tree });
        mock override => (fact_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary'], []);
    my $fact = mock {start => 1};

    is([$one->render(1, $fact, 'nest')], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->render(1, $fact, 'nest')],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            'nest',
            'summary',
            "\n"
        ],
        "Rendered simple line"
    );

    @summary = (['summary'], ['blob']);
    is(
        [$one->render(1, $fact, 'nest')],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            'nest',
            'summary',
            "\n",
            'blob',
        ],
        "Rendered blob line"
    );
};

subtest render_orphan => sub {
    my $one = $CLASS->new();
    local $ENV{T2_TERM_SIZE} = 80;

    my (@tag, @tree, @summary);
    my $m = mock $CLASS => sub {
        mock override => (tag          => sub { @tag });
        mock override => (tree         => sub { @tree });
        mock override => (fact_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary'], []);
    my $fact = mock {start => 1, nested => 2};

    is([$one->render_orphan(1, $fact)], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->render_orphan(1, $fact)],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            [1, '> > '],
            'summary',
            "\n"
        ],
        "Rendered simple line"
    );

    @summary = (['summary'], ['blob']);
    is(
        [$one->render_orphan(1, $fact)],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            [1, '> > '],
            'summary',
            "\n",
            'blob',
        ],
        "Rendered blob line"
    );
};

subtest preview => sub {
    my $one = $CLASS->new();
    local $ENV{T2_TERM_SIZE} = 80;

    my (@tag, @tree, @summary);
    my $m = mock $CLASS => sub {
        mock override => (tag          => sub { @tag });
        mock override => (tree         => sub { @tree });
        mock override => (fact_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary1', 'summary2'], []);
    my $fact = mock {start => 1, nested => 2};

    is([$one->preview(1, $fact)], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->preview(1, $fact)],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            [1, '> > '],
            'summary2',
            "\r"
        ],
        "preview simple line"
    );

    @summary = (['summary1', 'summary2'], ['blob']);
    is(
        [$one->preview(1, $fact)],
        [
            '[ atag ]',
            '  ',
            'tree',
            '  ',
            [1, '> > '],
            'summary2',
            "\r",
        ],
        "Blob ignored"
    );
};

subtest render_subtest => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    my $one = $CLASS->new(verbose => 1, out_std => $fh);
    local $ENV{T2_TERM_SIZE} = 80;

    my $fact = Test2::Harness::Fact->new(
        nested           => 0,
        name             => 'foo',
        number           => 4,
        is_subtest       => 'foo',
        event            => 1,
        increments_count => 1,

        result => Test2::Harness::Result->new(
            file             => 'foo.pl',
            name             => 'foo',
            job              => 2,
            nested           => 1,
            increments_count => 1,
            is_subtest       => 'foo',

            facts => [
                Test2::Harness::Fact->new(
                    nested           => 1,
                    name             => 'a',
                    number           => 1,
                    in_subtest       => 'foo',
                    increments_count => 1,
                    event            => 1,
                ),

                Test2::Harness::Fact->new(
                    nested           => 1,
                    name             => 'bar',
                    number           => 2,
                    is_subtest       => 'bar',
                    in_subtest       => 'foo',
                    event            => 1,
                    increments_count => 1,

                    result => Test2::Harness::Result->new(
                        file             => 'foo.pl',
                        name             => 'bar',
                        job              => 2,
                        nested           => 1,
                        increments_count => 1,
                        in_subtest       => 'foo',
                        is_subtest       => 'bar',

                        facts => [
                            Test2::Harness::Fact->new(
                                nested           => 2,
                                name             => 'aa',
                                number           => 1,
                                in_subtest       => 'bar',
                                increments_count => 1,
                                event            => 1,
                            ),
                            Test2::Harness::Fact->new(
                                nested           => 2,
                                name             => 'bb',
                                number           => 1,
                                in_subtest       => 'bar',
                                increments_count => 1,
                                event            => 1,
                            ),
                        ],
                    ),
                ),

                Test2::Harness::Fact->new(
                    nested           => 1,
                    name             => 'b',
                    number           => 3,
                    in_subtest       => 'foo',
                    increments_count => 1,
                    event            => 1,
                ),
            ],
        ),
    );

    my @out = $one->render_subtest(2, $fact);
    is(
        \@out,
        [
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ',                ['pass', 'foo'], "\n",
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ', [2, '| '  ],   ['pass', 'no summary'], "\n",
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ', [2, '+-'  ],   ['pass', 'bar'],        "\n",
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ', [2, '| | '],   ['pass', 'no summary'], "\n",
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ', [2, '| | '],   ['pass', 'no summary'], "\n",
            '          ',                                         '  ', [2, '| ^' ],                           "\n",
            ['tag', '['], ['pass', '  OK  '], ['tag', ']'], '  ', '  ', [2, '| '  ],   ['pass', 'no summary'], "\n",
            '          ',                                         '  ', [2, '^'   ],                           "\n",
        ],
        "Got subtest output"
    );

    $one->paint(@out);
    is($foo, <<"    EOT", "Rendered properly");
[  OK  ]    foo
[  OK  ]    | no summary
[  OK  ]    +-bar
[  OK  ]    | | no summary
[  OK  ]    | | no summary
            | ^
[  OK  ]    | no summary
            ^
    EOT
};

subtest update_state => sub {
    my $encoding_set = 0;
    my $m = mock $CLASS => (override => [encoding => sub { $encoding_set++ }]);
    my $one = $CLASS->new();

    $one->update_state(4, mock {event => 0, encoding => 0});
    is($one->counter, 0, "did not bump event counter");
    ok($one->jobs->{4}, "added job 4");
    is($one->jobs->{4}->{counter}, 1, "fact counter bumped for job 4");
    ok(!$encoding_set, "did not set encoding");

    $one->update_state(4, mock {event => 1, encoding => 1});
    is($one->counter, 1, "did bump event counter");
    is($one->jobs->{4}->{counter}, 2, "fact counter bumped for job 4");
    ok($encoding_set, "did set encoding");
};

subtest pick_renderer => sub {
    my $one = $CLASS->new();

    my @no_watch = (
        [1,  [nested => -1,    is_subtest => 0, in_subtest => 0], 'render'],
        [2,  [nested => -1,    is_subtest => 0, in_subtest => 1], 'render'],
        [3,  [nested => -1,    is_subtest => 1, in_subtest => 0], 'render'],
        [4,  [nested => -1,    is_subtest => 1, in_subtest => 1], 'render'],
        [5,  [nested => 0,     is_subtest => 0, in_subtest => 0], 'render'],
        [6,  [nested => 0,     is_subtest => 0, in_subtest => 1], 'render'],
        [7,  [nested => 0,     is_subtest => 1, in_subtest => 0], 'render_subtest'],
        [8,  [nested => 0,     is_subtest => 1, in_subtest => 1], undef],
        [9,  [nested => undef, is_subtest => 0, in_subtest => 0], 'render'],
        [10, [nested => undef, is_subtest => 0, in_subtest => 1], 'render'],
        [11, [nested => undef, is_subtest => 1, in_subtest => 0], 'render_subtest'],
        [12, [nested => undef, is_subtest => 1, in_subtest => 1], undef],
        [13, [nested => 1,     is_subtest => 0, in_subtest => 0], 'render_orphan'],
        [14, [nested => 1,     is_subtest => 0, in_subtest => 1], undef],
        [15, [nested => 1,     is_subtest => 1, in_subtest => 0], 'render_orphan'],
        [16, [nested => 1,     is_subtest => 1, in_subtest => 1], undef],
    );
    is($one->pick_renderer(mock {@{$_->[1]}}), $_->[2], "no-watch test $_->[0]") for @no_watch;

    $one->set_watch(1);
    my @watch = (
        [1,  [nested => -1,    is_subtest => 0, in_subtest => 0], 'render'],
        [2,  [nested => -1,    is_subtest => 0, in_subtest => 1], 'render'],
        [3,  [nested => -1,    is_subtest => 1, in_subtest => 0], 'render'],
        [4,  [nested => -1,    is_subtest => 1, in_subtest => 1], 'render'],
        [5,  [nested => 0,     is_subtest => 0, in_subtest => 0], 'render'],
        [6,  [nested => 0,     is_subtest => 0, in_subtest => 1], 'render'],
        [7,  [nested => 0,     is_subtest => 1, in_subtest => 0], 'render_subtest'],
        [8,  [nested => 0,     is_subtest => 1, in_subtest => 1], 'preview'],
        [9,  [nested => undef, is_subtest => 0, in_subtest => 0], 'render'],
        [10, [nested => undef, is_subtest => 0, in_subtest => 1], 'render'],
        [11, [nested => undef, is_subtest => 1, in_subtest => 0], 'render_subtest'],
        [12, [nested => undef, is_subtest => 1, in_subtest => 1], 'preview'],
        [13, [nested => 1,     is_subtest => 0, in_subtest => 0], 'render_orphan'],
        [14, [nested => 1,     is_subtest => 0, in_subtest => 1], 'preview'],
        [15, [nested => 1,     is_subtest => 1, in_subtest => 0], 'render_orphan'],
        [16, [nested => 1,     is_subtest => 1, in_subtest => 1], 'preview'],
    );
    is($one->pick_renderer(mock {@{$_->[1]}}), $_->[2], "watch test $_->[0]") for @watch;

};

subtest _process => sub {
    my (@fact, @start);
    my $m = mock $CLASS => (
        override => [
            pick_renderer => sub { 'test_render_fact' },
            render => sub { @start },
            tree => sub { 'tree' },
        ],
        add => [
            test_render_fact => sub { @fact },
        ],
    );

    my $one = $CLASS->new();
    $one->init_job(3)->{start} = 1;

    @fact  = ('fact',  'fact');
    @start = ('start', 'start');

    is(
        [$one->_process(3, mock({}), 0)],
        ['start', 'start', 'fact', 'fact'],
        "Rendered + start"
    );
    is(
        [$one->_process(3, mock({}), 0)],
        ['fact', 'fact'],
        "Do not repeat start"
    );

    $one->jobs->{3}->{start} = 1;
    is(
        [$one->_process(3, mock({result => mock({plan_errors => ['error1', 'error2']})}), 1)],
        [
            'start', 'start',

            ['tag', '['], ['fail',' PLAN '], ['tag', ']'],
            '  ', 'tree', '  ',
            ['fail', 'error1'],
            "\n",

            ['tag', '['], ['fail',' PLAN '], ['tag', ']'],
            '  ', 'tree', '  ',
            ['fail', 'error2'],
            "\n",

            'fact', 'fact',
        ],
        "Rendered + errors + start"
    );

    is(
        [$one->_process(3, mock({result => mock({plan_errors => []})}), 1)],
        ['fact', 'fact'],
        "No errors, no start"
    );
};

subtest process => sub {
    my $counter = 1;
    my %process;
    my $m = mock $CLASS => (
        override => [
            update_state => sub { $process{update_state} = $counter++ },
            _process     => sub { $process{_process}     = $counter++; 'stuff' },
            paint        => sub { $process{paint}        = $counter++ },
            do_watch     => sub { $process{do_watch}     = $counter++ },
            end_job      => sub { $process{end_job}      = $counter++ },
        ],
    );

    my $one = $CLASS->new();
    $one->init_job(3);

    $one->process(3, mock {});
    is(
        \%process,
        {
            update_state => 1,
            _process     => 2,
            paint        => 3,
            do_watch     => 4,
        },
        "Called methods in succession",
    );

    $counter = 1;
    %process = ();
    $one->process(3, mock {start => 1});
    is(
        \%process,
        {
            update_state => 1,
            do_watch     => 2,
        },
        "Stashed start, did not process it",
    );
    ok($one->jobs->{3}->{start}, "stashed the start");

    delete $one->jobs->{3}->{start};
    $one->set_verbose(1);
    $counter = 1;
    %process = ();
    $one->process(3, mock {start => 1});
    is(
        \%process,
        {
            update_state => 1,
            _process     => 2,
            paint        => 3,
            do_watch     => 4,
        },
        "'start' processed normally",
    );
    ok(!$one->jobs->{3}->{start}, "Did not stash the start");

    $counter = 1;
    %process = ();
    $one->process(3, mock {result => 1, nested => -1});
    is(
        \%process,
        {
            update_state => 1,
            _process     => 2,
            paint        => 3,
            do_watch     => 4,
            end_job      => 5,
        },
        "is end, ended job",
    );
};

done_testing;
