use Test2::Bundle::Extended -target => 'Test2::Harness::Renderer::EventStream';
use PerlIO;
use Test2::Event::Diag;
use Test2::Event::Encoding;
use Test2::Event::UnknownStderr;
use Test2::Event::UnknownStdout;
use Test2::Event::Generic;
use Test2::Event::Note;
use Test2::Event::Ok;
use Test2::Event::ParseError;
use Test2::Event::ParserSelect;
use Test2::Event::Plan;
use Test2::Event::ProcessFinish;
use Test2::Event::ProcessStart;
use Test2::Event::Skip;
use Test2::Event::Subtest;
use Test2::Harness::Job;
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

    ok($one->colors,       "Got colors");
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
        out_std      => $fh,
        colors       => {foo => 'color_foo', bar => 'color_bar', reset => 'color_reset'},
        graph_colors => [qw/color_a color_b color_c/],
    );
    $one->set_jobs(
        {
            0 => {slot => 0},
            1 => {slot => 1},
            2 => {slot => 2},
            3 => {slot => 0},
        }
    );

    $one->paint(
        'foo bar ',
        ['0',   'a'],   ' ',
        ['1',   'b'],   ' ',
        ['2',   'c'],   ' ',
        ['3',   'd'],   ' ',
        ['foo', 'foo ', 0],
        ['xxx', 'xxx'],
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
        ['0',   'a'],   ' ',
        ['1',   'b'],   ' ',
        ['2',   'c'],   ' ',
        ['3',   'd'],   ' ',
        ['foo', 'foo ', 0],
        ['xxx', 'xxx'],
        "\n",
    );
    ok(!$one->clear, "unset clear");

    is(
        $foo,
        "foo bar color_aacolor_reset color_bbcolor_reset color_cccolor_reset color_adcolor_reset color_foofoo xxxcolor_reset\n" . "\e[K" . "foo bar color_aacolor_reset color_bbcolor_reset color_cccolor_reset color_adcolor_reset color_foofoo xxxcolor_reset\n",
        "Painted string with clear"
    );
};

subtest encoding => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";

    my $layers = {map { $_ => 1 } PerlIO::get_layers($fh)};
    ok(!$layers->{utf8}, "utf8 is off");

    my $one = $CLASS->new(out_std => $fh);
    $one->encoding('utf8');

    $layers = {map { $_ => 1 } PerlIO::get_layers($fh)};
    ok($layers->{utf8}, "utf8 is on now");
};

subtest summary => sub {
    my $foo = '';
    open(my $fh, '>', \$foo) or die "$!";
    my $one = $CLASS->new(
        out_std => $fh,
        colors  => {failed => '[failed]', passed => '[passed]', reset => '[reset]'},
    );

    my $pass = mock {passed => 1, name => 'a passing result'};
    my $fail = mock {passed => 0, name => 'a failing result'};

    $one->summary([$pass, $pass, $pass]);
    is($foo, "\n[passed]=== ALL TESTS SUCCEEDED ===\n[reset]\n", "All pass");

    $foo = '';
    open($fh, '>', \$foo) or die "$!";
    $one = $CLASS->new(
        out_std => $fh,
        colors  => {failed => '[failed]', passed => '[passed]', reset => '[reset]'},
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
    my $l   = $one->listen;
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
            call jobs => {5 => {slot => 0}};
            call slots => [5];
        },
        "Added job"
    );

    $one->init_job(3);
    like(
        $one,
        object {
            call jobs => {5 => {slot => 0}, 3 => {slot => 1}};
            call slots => [5, 3];
        },
        "Added another job"
    );

    $one->end_job(3);
    like(
        $one,
        object {
            call jobs => {5 => {slot => 0}};
            call slots => [5, undef];    # Undef is intentional, preserve ordering
        },
        "Ended job"
    );

    $one->end_job(5);
    like(
        $one,
        object {
            call jobs => {};
            call slots => [undef, undef];    # The undef's are intentional
        },
        "removed another job"
    );
};

subtest verbose_tag => sub {
    my $one = $CLASS->new(verbose => 1);

    is(
        [$one->_tag(Test2::Event::Generic->new(no_display => 1))],
        [],
        "Do not show hidden events"
    );

    is(
        [$one->_tag(Test2::Event::ProcessStart->new(file => 'foo.t'))],
        [qw/LAUNCH file/],
        "start event"
    );

    is(
        [$one->_tag(Test2::Event::ParserSelect->new(parser_class => 'Foo'))],
        [qw/PARSER parser_select/],
        "parser selection"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(pass => 0))],
        ['NOT OK', 'fail'],
        "failure (not ok)"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(pass => 1))],
        ['  OK  ', 'pass'],
        "pass (ok)"
    );

    is(
        [$one->_tag(Test2::Event::Skip->new(reason => 'xxx'))],
        ['  OK  ', 'skip'],
        "pass (skip)"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(todo => 'xxx'))],
        ['NOT OK', 'todo'],
        "effective pass (todo)"
    );

    is(
        [$one->_tag(Test2::Event::Plan->new(max => 1))],
        [' PLAN ', 'plan'],
        "set plan"
    );

    is(
        [$one->_tag(Test2::Event::Generic->new(summary => " "))],
        [],
        "Nothing to display"
    );

    is(
        [$one->_tag(Test2::Event::Note->new(message => "xxx"))],
        [' NOTE ', 'note'],
        "Note"
    );

    is(
        [$one->_tag(Test2::Event::Diag->new(message => "xxx"))],
        [' DIAG ', 'diag'],
        "Diag"
    );

    is(
        [$one->_tag(Test2::Event::Subtest->new(causes_fail => 1))],
        ['FAILED', 'failed'],
        "Subtest failure"
    );

    is(
        [$one->_tag(Test2::Event::Plan->new(directive => 'SKIP', reason => 'because'))],
        ['SKIP!!', 'skipall'],
        "Skipall for entire process"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => -1,
                    subevents => [Test2::Event::Plan->new(directive => 'SKIP', reason => 'because')],
                )
            )
        ],
        ['SKIP!!', 'skipall'],
        "Skipall in subtest"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => -1,
                    subevents => [Test2::Event::Plan->new(max => 1)],
                )
            )
        ],
        ['PASSED', 'passed'],
        "Subtest Success"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => 0,
                    subevents => [Test2::Event::Plan->new(max => 1)],
                )
            )
        ],
        ['PASSED', 'passed'],
        "Subtest Success nested"
    );

    is(
        [$one->_tag(Test2::Event::Encoding->new(encoding => 'utf8'))],
        ['ENCODE', 'encoding'],
        "Encoding event"
    );

    is(
        [$one->_tag(Test2::Event::UnknownStderr->new(output => "xyz"))],
        ['STDERR', 'stderr'],
        "random stderr"
    );

    is(
        [$one->_tag(Test2::Event::UnknownStdout->new(output => "xyz"))],
        ['STDOUT', 'stdout'],
        "random stdout message"
    );

    is(
        [$one->_tag(Test2::Event::ParseError->new(parse_error => 'foo'))],
        ['PARSER', 'parser'],
        "Parse error"
    );

    is(
        [$one->_tag(Test2::Event::Generic->new(summary => 'bar'))],
        [' ???? ', 'unknown'],
        "unknown"
    );
};

subtest quiet_tag => sub {
    my $one = $CLASS->new(verbose => 0);

    is(
        [$one->_tag(Test2::Event::Generic->new(no_display => 1))],
        [],
        "Do not show hidden events"
    );

    is(
        [$one->_tag(Test2::Event::ProcessStart->new(file => 'foo.t'))],
        [qw/LAUNCH file/],
        "start event"
    );

    is(
        [$one->_tag(Test2::Event::ParserSelect->new(parser_class => 'Foo'))],
        [],
        "parser selection"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(pass => 0))],
        ['NOT OK', 'fail'],
        "failure (not ok)"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(pass => 1))],
        [],
        "pass (ok)"
    );

    is(
        [$one->_tag(Test2::Event::Skip->new(reason => 'xxx'))],
        [],
        "pass (skip)"
    );

    is(
        [$one->_tag(Test2::Event::Ok->new(todo => 'xxx'))],
        [],
        "effective pass (todo)"
    );

    is(
        [$one->_tag(Test2::Event::Plan->new(max => 1))],
        [],
        "set plan"
    );

    is(
        [$one->_tag(Test2::Event::Generic->new(summary => " "))],
        [],
        "Nothing to display"
    );

    is(
        [$one->_tag(Test2::Event::Note->new(message => "xxx"))],
        [],
        "Note"
    );

    is(
        [$one->_tag(Test2::Event::Diag->new(message => "xxx"))],
        [' DIAG ', 'diag'],
        "Diag"
    );

    is(
        [$one->_tag(Test2::Event::Subtest->new(causes_fail => 1))],
        ['FAILED', 'failed'],
        "Subtest failure"
    );

    is(
        [$one->_tag(Test2::Event::Plan->new(directive => 'SKIP', reason => 'because'))],
        ['SKIP!!', 'skipall'],
        "Skipall for entire process"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => -1,
                    subevents => [Test2::Event::Plan->new(directive => 'SKIP', reason => 'because')],
                )
            )
        ],
        ["SKIP!!", 'skipall'],
        "Skipall in subtest"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => -1,
                    subevents => [Test2::Event::Plan->new(max => 1)],
                )
            )
        ],
        ['PASSED', 'passed'],
        "Subtest Success"
    );

    is(
        [
            $one->_tag(
                Test2::Event::Subtest->new(
                    pass      => 1,
                    nested    => 0,
                    subevents => [Test2::Event::Plan->new(max => 1)],
                )
            )
        ],
        [$one->_tag(mock {nested => 0, result => mock {plans => []}})],
        [],
        "Subtest Success nested"
    );

    is(
        [$one->_tag(Test2::Event::Encoding->new(encoding => 'utf8'))],
        [],
        "Encoding event"
    );

    is(
        [$one->_tag(Test2::Event::UnknownStderr->new(output => "xyz"))],
        ['STDERR', 'stderr'],
        "random stderr"
    );

    is(
        [$one->_tag(Test2::Event::UnknownStdout->new(output => "xyz"))],
        [],
        "random stdout message"
    );

    is(
        [$one->_tag(Test2::Event::ParseError->new(parse_error => 'foo'))],
        ['PARSER', 'parser'],
        "Parse error"
    );

    is(
        [$one->_tag(Test2::Event::Generic->new(summary => 'bar'))],
        [],
        "unknown"
    );
};

subtest tag => sub {
    my $one = $CLASS->new(verbose => 1);

    is(
        [$one->tag(mock {increments_count => 1, causes_fail => 1})],
        [['tag', '['], ['fail', 'NOT OK'], ['tag', ']']],
        "failure (not ok)"
    );

    is(
        [$one->tag(mock {increments_count => 1})],
        [['tag', '['], ['pass', '  OK  '], ['tag', ']']],
        "pass (ok)"
    );

    $one = $CLASS->new(verbose => 0);

    is(
        [$one->tag(mock {increments_count => 1, causes_fail => 1})],
        [['tag', '['], ['fail', 'NOT OK'], ['tag', ']']],
        "failure (not ok)"
    );

    is(
        [$one->tag(mock {increments_count => 1})],
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
        [$one->tree(2, Test2::Event::Ok->new(pass => 1))],
        [[2, '+'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with mark"
    );

    is(
        [$one->tree(2, Test2::Event::ProcessStart->new(file => 'foo.t'))],
        [['mark', '_'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with start mark"
    );

    is(
        [
            $one->tree(
                2,
                Test2::Event::Subtest->new(
                    pass   => 1,
                    nested => -1,
                )
            )
        ],
        [['mark', '='], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with result mark"
    );

    is(
        [
            $one->tree(
                2,
                Test2::Event::Subtest->new(
                    pass   => 1,
                    nested => 1,
                )
            )
        ],
        [[2, '+'], ' ', ' ', ' ', [5, ':'], ' ', [3, '|']],
        "Got tree with result mark for nested subtest"
    );

    is(
        [$one->tree(5, Test2::Event::Ok->new(pass => 1))],
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

subtest event_summary => sub {
    my $one = $CLASS->new(verbose => 1);
    local $ENV{T2_TERM_SIZE} = 80;

    is(
        [$one->event_summary(Test2::Event::Generic->new(summary => 'xyz'), ["abc"])],
        [[['unknown', 'xyz']], []],
        "Got summary"
    );

    is(
        [$one->event_summary(Test2::Event::Generic->new(summary => "abc\ndef\nghi"), ["abc"])],
        [
            [
                ['unknown', "abc"],
                ['unknown', "def"],
                ['unknown', "ghi"],
            ],
            []
        ],
        "Multi-line summary"
    );

    is(
        [$one->event_summary(Test2::Event::Generic->new(summary => "aaa" x 100), ["abc"])],
        [
            [
                ['blob', '----- START -----'],
            ],
            [
                ['unknown', "aaa" x 100],
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
        mock override => (tag           => sub { @tag });
        mock override => (tree          => sub { @tree });
        mock override => (event_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary'], []);
    my $event = mock {start => 1};

    is([$one->render(1, $event, 'nest')], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->render(1, $event, 'nest')],
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
        [$one->render(1, $event, 'nest')],
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
        mock override => (tag           => sub { @tag });
        mock override => (tree          => sub { @tree });
        mock override => (event_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary'], []);
    my $event = mock {start => 1, nested => 2};

    is([$one->render_orphan(1, $event)], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->render_orphan(1, $event)],
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
        [$one->render_orphan(1, $event)],
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
        mock override => (tag           => sub { @tag });
        mock override => (tree          => sub { @tree });
        mock override => (event_summary => sub { @summary });
    };

    @tree = 'tree';
    @summary = (['summary1', 'summary2'], []);
    my $event = mock {start => 1, nested => 2};

    is([$one->preview(1, $event)], [], "no tag, no render");

    @tag = '[ atag ]';

    is(
        [$one->preview(1, $event)],
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
        [$one->preview(1, $event)],
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

    my $event = Test2::Event::Subtest->new(
        nested     => 0,
        name       => 'foo',
        number     => 4,
        subtest_id => 'foo',
        pass       => 1,

        subevents => [
            Test2::Event::Ok->new(
                nested     => 1,
                name       => 'a',
                in_subtest => 'foo',
                pass       => 1,
            ),

            Test2::Event::Subtest->new(
                file       => 'foo.pl',
                name       => 'bar',
                nested     => 1,
                in_subtest => 'foo',
                subtest_id => 'bar',
                pass       => 1,

                subevents => [
                    Test2::Event::Ok->new(
                        nested     => 2,
                        name       => 'aa',
                        in_subtest => 'bar',
                        pass       => 1,
                    ),

                    Test2::Event::Ok->new(
                        nested     => 2,
                        name       => 'bb',
                        in_subtest => 'bar',
                        pass       => 1,
                    ),

                    Test2::Event::Plan->new(
                        nested     => 2,
                        in_subtest => 'bar',
                        max        => 2,
                    ),
                ],
            ),

            Test2::Event::Plan->new(
                nested     => 1,
                in_subtest => 'foo',
                max        => 2,
            ),
        ],
    );

    my @out = $one->render_subtest(2, $event);
    is(
        \@out,
        [
            ['tag', '['], ['passed', 'PASSED'], ['tag', ']'], '  ', '  ', ['passed', 'foo'], "\n",
            ['tag', '['], ['pass',   '  OK  '], ['tag', ']'], '  ', '  ', [2, '| '],   ['pass',   'a'],                    "\n",
            ['tag', '['], ['passed', 'PASSED'], ['tag', ']'], '  ', '  ', [2, '+-'],   ['passed', 'bar'],                  "\n",
            ['tag', '['], ['pass',   '  OK  '], ['tag', ']'], '  ', '  ', [2, '| | '], ['pass',   'aa'],                   "\n",
            ['tag', '['], ['pass',   '  OK  '], ['tag', ']'], '  ', '  ', [2, '| | '], ['pass',   'bb'],                   "\n",
            ['tag', '['], ['plan',   ' PLAN '], ['tag', ']'], '  ', '  ', [2, '| | '], ['plan',   'Plan is 2 assertions'], "\n",
            '          ', '  ', [2, '| ^'], "\n",
            ['tag', '['], ['plan', ' PLAN '], ['tag', ']'], '  ', '  ', [2, '| '], ['plan', 'Plan is 2 assertions'], "\n",
            '          ', '  ', [2, '^'], "\n",
        ],
        "Got subtest output"
    );

    $one->paint(@out);
    is($foo, <<"    EOT", "Rendered properly");
[PASSED]    foo
[  OK  ]    | a
[PASSED]    +-bar
[  OK  ]    | | aa
[  OK  ]    | | bb
[ PLAN ]    | | Plan is 2 assertions
            | ^
[ PLAN ]    | Plan is 2 assertions
            ^
    EOT
};

subtest update_state => sub {
    my $encoding_set = 0;
    my $m            = mock $CLASS => (override => [encoding => sub { $encoding_set++ }]);
    my $one          = $CLASS->new();

    $one->update_state(4, Test2::Event::Generic->new(summary => 'foo'));
    is($one->counter, 1, "bumped event counter");
    ok($one->jobs->{4}, "added job 4");
    is($one->jobs->{4}->{counter}, 1, "event counter bumped for job 4");
    ok(!$encoding_set, "did not set encoding");

    $one->update_state(4, Test2::Event::Encoding->new(encoding => 'foo'));
    is($one->counter,              2, "bumped event counter");
    is($one->jobs->{4}->{counter}, 2, "event counter bumped for job 4");
    ok($encoding_set, "did set encoding");
};

subtest pick_renderer => sub {
    my $one = $CLASS->new();

    my @no_watch = (
        [1, [nested => -1, in_subtest => 0], 'render'],
        [2, [nested => -1, in_subtest => 1], 'render'],
        [3, [nested => -1, subtest_id => 1, in_subtest => 0], 'render'],
        [4, [nested => -1, subtest_id => 1, in_subtest => 1], 'render'],
        [5, [nested => 0, in_subtest => 0], 'render'],
        [6, [nested => 0, in_subtest => 1], 'render'],
        [7, [nested => 0, subtest_id => 1, in_subtest => 0], 'render_subtest'],
        [8, [nested => 0, subtest_id => 1, in_subtest => 1], undef],
        [9,  [nested => undef, in_subtest => 0], 'render'],
        [10, [nested => undef, in_subtest => 1], 'render'],
        [11, [nested => undef, subtest_id => 1, in_subtest => 0], 'render_subtest'],
        [12, [nested => undef, subtest_id => 1, in_subtest => 1], undef],
        [13, [nested => 1, in_subtest => 0], 'render_orphan'],
        [14, [nested => 1, in_subtest => 1], undef],
        [15, [nested => 1, subtest_id => 1, in_subtest => 0], 'render_orphan'],
        [16, [nested => 1, subtest_id => 1, in_subtest => 1], undef],
    );
    is($one->pick_renderer(mock { @{$_->[1]} }), $_->[2], "no-watch test $_->[0]") for @no_watch;

    $one->set_watch(1);
    my @watch = (
        [1, [nested => -1, in_subtest => 0], 'render'],
        [2, [nested => -1, in_subtest => 1], 'render'],
        [3, [nested => -1, subtest_id => 1, in_subtest => 0], 'render'],
        [4, [nested => -1, subtest_id => 1, in_subtest => 1], 'render'],
        [5, [nested => 0, in_subtest => 0], 'render'],
        [6, [nested => 0, in_subtest => 1], 'render'],
        [7, [nested => 0, subtest_id => 1, in_subtest => 0], 'render_subtest'],
        [8, [nested => 0, subtest_id => 1, in_subtest => 1], 'preview'],
        [9,  [nested => undef, in_subtest => 0], 'render'],
        [10, [nested => undef, in_subtest => 1], 'render'],
        [11, [nested => undef, subtest_id => 1, in_subtest => 0], 'render_subtest'],
        [12, [nested => undef, subtest_id => 1, in_subtest => 1], 'preview'],
        [13, [nested => 1, in_subtest => 0], 'render_orphan'],
        [14, [nested => 1, in_subtest => 1], 'preview'],
        [15, [nested => 1, subtest_id => 1, in_subtest => 0], 'render_orphan'],
        [16, [nested => 1, subtest_id => 1, in_subtest => 1], 'preview'],
    );
    is($one->pick_renderer(mock { @{$_->[1]} }), $_->[2], "watch test $_->[0]") for @watch;

};

subtest _process => sub {
    my (@event, @plan_errors, @start);
    my $m = mock $CLASS => (
        override => [
            pick_renderer => sub { 'test_render_event' },
            render        => sub { @start },
            tree          => sub { 'tree' },
            _plan_errors  => sub { @plan_errors },
        ],
        add => [
            test_render_event => sub { @event },
        ],
    );

    my $one = $CLASS->new();
    $one->init_job(3)->{start} = 1;

    @event  = ('event',  'event');
    @start = ('start', 'start');

    is(
        [$one->_process(3, mock({}), 0)],
        ['start', 'start', 'event', 'event'],
        "Rendered + start"
    );
    is(
        [$one->_process(3, mock({}), 0)],
        ['event', 'event'],
        "Do not repeat start"
    );

    $one->jobs->{3}->{start} = 1;

    @plan_errors = ('error1', 'error2');
    is(
        [$one->_process(3, mock({result => mock({events => []})}), 1)],
        [
            'start', 'start',

            ['tag', '['], ['fail', ' PLAN '], ['tag', ']'],
            '  ', 'tree', '  ',
            ['fail', 'error1'],
            "\n",

            ['tag', '['], ['fail', ' PLAN '], ['tag', ']'],
            '  ', 'tree', '  ',
            ['fail', 'error2'],
            "\n",

            'event', 'event',
        ],
        "Rendered + errors + start"
    );

    @plan_errors = ();
    is(
        [$one->_process(3, mock({result => mock({events => []})}), 1)],
        ['event', 'event'],
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

    my $j = mock {
        id => 3,
    };
    $one->process($j, mock {});
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
    $one->process($j, Test2::Event::ProcessStart->new(file => 'foo.t'));
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
    $one->process($j, Test2::Event::ProcessStart->new(file => 'foo.t'));
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
    $one->process(
        $j,
        Test2::Event::ProcessFinish->new(
            result => Test2::Harness::Result->new(
                job  => 3,
                file => 'foo.t',
                name => 'foo.t',
            )
        )
    );
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
