use Test2::V0 -target => 'Test2::Harness::Util::TapParser';

use ok $CLASS => qw/parse_stdout_tap parse_stderr_tap/;

imported_ok qw/parse_stdout_tap parse_stderr_tap/;

subtest parse_stderr_integration => sub {
    ok(!parse_stderr_tap("foo bar baz"), "TAP stderr must start with a '#'");

    is(
        parse_stderr_tap("# foo"),
        {
            trace => {nested  => 0},
            hubs  => [{nested => 0}],
            info  => [
                {
                    debug   => 1,
                    details => 'foo',
                    tag     => 'DIAG',
                }
            ],
            from_tap => {
                details => '# foo',
                source  => 'STDERR',
            },
        },
        "Got expected facets for diag"
    );

    is(
        parse_stderr_tap("    # foo"),
        {
            trace => {nested  => 1},
            hubs  => [{nested => 1}],
            info  => [
                {
                    debug   => 1,
                    details => 'foo',
                    tag     => 'DIAG',
                }
            ],
            from_tap => {
                details => '    # foo',
                source  => 'STDERR',
            },
        },
        "Got expected facets for indented diag"
    );
};

subtest parse_stdout_tap_integration => sub {
    ok(!parse_stdout_tap("foo"), "Not everything is TAP");

    is(
        parse_stdout_tap("# A comment"),
        {
            trace => {nested  => 0},
            hubs  => [{nested => 0}],
            info  => [
                {
                    debug   => 0,
                    details => 'A comment',
                    tag     => 'NOTE',
                }
            ],
            from_tap => {
                details => '# A comment',
                source  => 'STDOUT',
            },
        },
        "Got expected facets for a comment"
    );

    is(
        parse_stdout_tap("    #     An indented multiline padded comment\n    #     line 2"),
        {
            trace => {nested  => 1},
            hubs  => [{nested => 1}],
            info  => [
                {
                    debug   => 0,
                    details => "    An indented multiline padded comment\n    line 2",
                    tag     => 'NOTE',
                }
            ],
            from_tap => {
                details => "    #     An indented multiline padded comment\n    #     line 2",
                source  => 'STDOUT',
            },
        },
        "Got expected facets for an indented multiline padded comment"
    );


    is(
        parse_stdout_tap('TAP version 42'),
        {
            trace    => {nested  => 0},
            hubs     => [{nested => 0}],
            from_tap => {
                details => 'TAP version 42',
                source  => 'STDOUT',
            },
            about => {details => 'TAP version 42'},
            info => [{tag => 'INFO', details => 'TAP version 42', debug => FDNE}],
        },
        "Parsed TAP version"
    );

    subtest plan => sub {
        is(
            parse_stdout_tap('1..5'),
            {
                trace    => {nested  => 0},
                hubs     => [{nested => 0}],
                from_tap => {details => '1..5', source => 'STDOUT'},
                plan     => {count   => 5, skip => FDNE, details => FDNE},
            },
            "Parsed the plan"
        );

        is(
            parse_stdout_tap('1..0'),
            {
                hubs  => [{nested => 0}],
                trace => {nested  => 0},
                from_tap => {details => '1..0', source => 'STDOUT'},
                plan     => {count   => 0,      skip   => 1, details => 'no reason given'},
            },
            "Parsed the skip plan"
        );

        is(
            parse_stdout_tap('1..0 # SKIP foo bar baz'),
            {
                hubs  => [{nested => 0}],
                trace => {nested  => 0},
                from_tap => {details => '1..0 # SKIP foo bar baz', source => 'STDOUT'},
                plan     => {count   => 0,                         skip   => 1, details => 'foo bar baz'},
            },
            "Parsed the skip + reason plan"
        );
    };

    my @conds = (
        {nest => 0, prefix => '',         bs => '',    pass => T},
        {nest => 1, prefix => '    ',     bs => '',    pass => T},
        {nest => 0, prefix => 'not ',     bs => '',    pass => F},
        {nest => 1, prefix => '    not ', bs => '',    pass => F},
        {nest => 0, prefix => '',         bs => ' { ', pass => T},
        {nest => 1, prefix => '    ',     bs => ' { ', pass => T},
        {nest => 0, prefix => 'not ',     bs => ' { ', pass => F},
        {nest => 1, prefix => '    not ', bs => ' { ', pass => F},
    );

    subtest "$_->{prefix}ok" => sub {
        my $prefix = $_->{prefix};
        my $nest   = $_->{nest};
        my $pass   = $_->{pass};
        my $bs     = $_->{bs};

        my %common = (
            from_tap => T(),
            trace    => {nested => $nest},
            hubs     => [{nested => $nest}],
            $bs ? (parent => {details => E}, harness => {subtest_start => 1}) : (),
        );

        is(
            parse_stdout_tap("${prefix}ok$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for plain '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok -$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for plain '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok 1$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => 1,
                },
            },
            "Got expected facets for numbered '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 1 -$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => 1,
                },
            },
            "Got expected facets for numbered '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok foo $bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for named '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
            },
            "Got expected facets for named and numbered '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
            },
            "Got expected facets for named and numbered '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok - foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for named '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# TODO"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'TODO', details => ''},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with odo"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo$bs # TODO xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'TODO', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with todo and reason"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# SKIP"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => ''},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with skip"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# SKIP xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with skip and reason"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# TODO & SKIP xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => 'xxx'},
                    {tag => 'TODO', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with todo+skip and reason"
        );
        }
        for @conds;
};

subtest parse_tap_buffered_subtest => sub {
    is(
        $CLASS->parse_tap_buffered_subtest('ok {'),
        {
            %{$CLASS->parse_tap_ok('ok')},
            parent  => {details       => ''},
            harness => {subtest_start => 1},
        },
        "Simple bufferd subtest"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 {'),
        {
            %{$CLASS->parse_tap_ok('ok 1')},
            parent  => {details       => ''},
            harness => {subtest_start => 1},
        },
        "Simple bufferd subtest with number"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 - foo {'),
        {
            %{$CLASS->parse_tap_ok('ok 1 - foo')},
            parent  => {details       => 'foo'},
            harness => {subtest_start => 1},
        },
        "Simple bufferd subtest with number and name"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 - foo { # TODO foo bar baz'),
        {
            %{$CLASS->parse_tap_ok('ok 1 - foo # TODO foo bar baz')},
            parent  => {details       => 'foo'},
            harness => {subtest_start => 1},
        },
        "Simple bufferd subtest with number and name and directive"
    );
};

subtest parse_tap_version => sub {
    is(
        $CLASS->parse_tap_version("TAP version 123"),
        {
            about => {details => 'TAP version 123'},
            info => [{tag => 'INFO', debug => 0, details => 'TAP version 123'}],
        },
        "Got version facets"
    );

    is(
        $CLASS->parse_tap_version("123"),
        undef,
        "No facets for invalid version line"
    );
};

subtest parse_tap_plan => sub {
    is(
        $CLASS->parse_tap_plan("1..5"),
        {plan => {count => 5, skip => F, details => ''}},
        "Simple plan, got expected number, details is an empty string, not undef or 0"
    );

    is(
        $CLASS->parse_tap_plan("1..9001"),
        {plan => {count => 9001, skip => F, details => ''}},
        "Simple plan, got expected large number"
    );

    is(
        $CLASS->parse_tap_plan("1..0"),
        {plan => {count => 0, skip => T, details => 'no reason given'}},
        "Simple skip"
    );

    is(
        $CLASS->parse_tap_plan("1..0 # SKIP Foo bar baz"),
        {plan => {count => 0, skip => T, details => 'Foo bar baz'}},
        "Simple skip with reason"
    );

    is(
        $CLASS->parse_tap_plan("1..2 x"),
        {
            plan => {count => 2,        skip  => F, details => ''},
            info => [{tag  => 'PARSER', debug => 1, details => 'Extra characters after plan.'}],
        },
        "Extra characters in plan"
    );

    is(
        $CLASS->parse_tap_plan(".."),
        undef,
        "No facets without a plan"
    );
};

subtest parse_tap_bail => sub {
    is(
        $CLASS->parse_tap_bail('Bail out!'),
        {control => {halt => 1, details => ''}},
        "Expected facets for a bail, no reason means details is an empty string"
    );

    is(
        $CLASS->parse_tap_bail('Bail out! foo bar baz'),
        {control => {halt => 1, details => 'foo bar baz'}},
        "Expected facets for a bail with reason"
    );

    is(
        $CLASS->parse_tap_bail('Bail'),
        undef,
        "No facets with invalid bail-out"
    );
};

subtest parse_tap_comment => sub {
    is(
        $CLASS->parse_tap_comment('# foo bar baz'),
        {info => [{tag => 'NOTE', debug => 0, details => 'foo bar baz'}]},
        "Got expected facets for a simple comment"
    );

    is(
        $CLASS->parse_tap_comment("# foo\n# bar\n# baz"),
        {info => [{tag => 'NOTE', debug => 0, details => "foo\nbar\nbaz"}]},
        "Striped all '#' out of multi-line comment"
    );

    is(
        $CLASS->parse_tap_comment("    # foo\n    # bar\n    # baz"),
        {info => [{tag => 'NOTE', debug => 0, details => "foo\nbar\nbaz"}]},
        "Striped all '#' out of multi-line indented comment"
    );

    is(
        $CLASS->parse_tap_comment("foo # bar baz"),
        undef,
        "Not a comment"
    );
};

subtest parse_tap_ok => sub {
    is(
        $CLASS->parse_tap_ok("ok"),
        {assert => {pass => T, no_debug => 1, details => ''}},
        "Got facets for simple ok, no name means details is an empty string"
    );

    is(
        $CLASS->parse_tap_ok("not ok"),
        {assert => {pass => F, no_debug => 1, details => ''}},
        "Got facets for simple not ok, no name means details is an empty string"
    );

    is(
        $CLASS->parse_tap_ok("ok foo"),
        {assert => {pass => T, no_debug => 1, details => 'foo'}},
        "Got facets for simple named ok"
    );

    is(
        $CLASS->parse_tap_ok("ok - foo"),
        {assert => {pass => T, no_debug => 1, details => 'foo'}},
        "Got facets for simple named ok with dash"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 foo"),
        {assert => {pass => T, no_debug => 1, details => 'foo', number => 42}},
        "Got facets for simple named ok with number"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 - foo"),
        {assert => {pass => T, no_debug => 1, details => 'foo', number => 42}},
        "Got facets for simple named ok with number and dash"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 -"),
        {assert => {pass => T, no_debug => 1, details => '', number => 42}},
        "Got facets for simple named ok with number and dash, but no name"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - foo"),
        {assert => {pass => F, no_debug => 1, details => 'foo', number => 42}},
        "Got facets for simple named not ok with number and dash"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 - foo"),
        {assert => {pass => T, no_debug => 1, details => 'foo', number => 42}},
        "Got facets for simple named ok with number and dash"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - foo # TODO"),
        {
            assert => {
                pass     => F,       # Yes really, do not change this to true!
                no_debug => 1,
                details  => 'foo',
                number   => 42
            },
            amnesty => [{tag => 'TODO', details => ''}],
        },
        "ok with todo directive"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 - foo # SKIP"),
        {
            assert  => {pass => T,      no_debug => 1, details => 'foo', number => 42},
            amnesty => [{tag => 'SKIP', details  => ''}],
        },
        "ok with skip directive"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - foo # TODO & SKIP"),
        {
            assert => {
                pass     => F,       # Yes really, do not change this to true!
                no_debug => 1,
                details  => 'foo',
                number   => 42
            },
            amnesty => [
                {tag => 'SKIP', details => ''},
                {tag => 'TODO', details => ''},
            ],
        },
        "ok with todo and skip directives"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - foo # TODO foo bar baz"),
        {
            assert => {
                pass     => F,       # Yes really, do not change this to true!
                no_debug => 1,
                details  => 'foo',
                number   => 42
            },
            amnesty => [{tag => 'TODO', details => 'foo bar baz'}],
        },
        "ok with todo directive and reason"
    );

    is(
        $CLASS->parse_tap_ok("ok 42 - foo # SKIP foo bar baz"),
        {
            assert  => {pass => T,      no_debug => 1, details => 'foo', number => 42},
            amnesty => [{tag => 'SKIP', details  => 'foo bar baz'}],
        },
        "ok with skip directive and reason"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - foo # TODO & SKIP foo bar baz"),
        {
            assert => {
                pass     => F,       # Yes really, do not change this to true!
                no_debug => 1,
                details  => 'foo',
                number   => 42
            },
            amnesty => [
                {tag => 'SKIP', details => 'foo bar baz'},
                {tag => 'TODO', details => 'foo bar baz'},
            ],
        },
        "ok with todo and skip directives and name"
    );

    is(
        $CLASS->parse_tap_ok("not ok 42 - Subtest: xxx"),
        {
            assert => {pass    => F, no_debug => 1, details => 'Subtest: xxx', number => 42},
            parent => {details => 'xxx'},
        },
        "Parsed subtest"
    );

    is(
        $CLASS->parse_tap_ok("ok- foo"),
        {
            assert => {pass => 1,        no_debug => 1,                                              details => 'foo'},
            info   => [{tag => 'PARSER', details  => "'ok' is not immediately followed by a space.", debug   => 1}],
        },
        "Parse error, no space"
    );

    is(
        $CLASS->parse_tap_ok("ok  42  foo"),
        {
            assert => {pass => 1,        no_debug => 1,                        details => 'foo', number => 42},
            info   => [{tag => 'PARSER', details  => "Extra space after 'ok'", debug   => 1}],
        },
        "Parse error, extra space"
    );

    is(
        $CLASS->parse_tap_ok("ok foo#TODOxxx"),
        {
            assert  => {pass => 1,      no_debug => 1, details => 'foo'},
            amnesty => [{tag => 'TODO', details  => 'xxx'}],
            info    => [
                {tag => 'PARSER', details => "No space before the '#' for the 'TODO' directive.", debug => 1},
                {tag => 'PARSER', details => "No space between 'TODO' directive and reason.",     debug => 1},
            ],
        },
        "Parse error, missing directive spaces"
    );
};

done_testing;
