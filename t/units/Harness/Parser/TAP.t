use Test2::Bundle::Extended -target => 'Test2::Harness::Parser::TAP';

isa_ok($CLASS, 'Test2::Harness::Parser');
can_ok($CLASS, qw/subtests sid last_nest/);

subtest morph => sub {
    my $one = bless {}, $CLASS;
    $one->morph;

    like(
        $one,
        {subtests => [], sid => 'A', last_nest => 0},
        "Morph set some defaults"
    );
};

subtest parse_tap_version => sub {
    my $one = bless {}, $CLASS;

    ok(!$one->parse_tap_version("ok"), "Not a version");

    like(
        $one->parse_tap_version('TAP version 13'),
        object { call summary => 'Producer is using TAP version 13.' },
        'Parsed version'
    );

    like(
        $one->parse_tap_version('TAP version 55.5'),
        object { call summary => 'Producer is using TAP version 55.5.' },
        'Parsed version'
    );
};

subtest parse_tap_plan => sub {
    my $one = bless {}, $CLASS;

    ok(!$one->parse_tap_plan('0..1'), "not a plan 0..1");
    ok(!$one->parse_tap_plan('foo'), "not a plan foo");

    like(
        $one->parse_tap_plan('1..5'),
        object {
            call summary => 'Plan is 5 assertions';
            call sets_plan => [5, undef, undef];
        },
        "Got simple plan"
    );

    like(
        $one->parse_tap_plan('1..0'),
        object {
            call summary => "Plan is 'SKIP', no reason given";
            call sets_plan => [0, 'SKIP', 'no reason given'];
        },
        "Got simple skip"
    );

    like(
        $one->parse_tap_plan('1..0 # SkIp foo'),
        object {
            call summary => "Plan is 'SKIP', foo";
            call sets_plan => [0, 'SKIP', 'foo'];
        },
        "Got skip with reason"
    );

    like(
        [$one->parse_tap_plan('1..0 xxx')],
        [
            object {
                call summary => "Plan is 'SKIP', no reason given";
                call sets_plan => [0, 'SKIP', 'no reason given'];
            },
            object {
                call parse_error => "Extra characters after plan.";
            },
        ],
        "Extra characters"
    );
};

subtest parse_tap_bail => sub {
    my $one = bless {}, $CLASS;
    ok(!$one->parse_tap_bail('ok'), "not a bailout");

    like(
        $one->parse_tap_bail('Bail out!'),
        object {
            call summary     => 'Bail out!';
            call event       => T();
            call terminate   => 255;
            call causes_fail => 1;
        },
        "Got bail"
    );

    like(
        $one->parse_tap_bail('Bail out! xxx'),
        object {
            call summary     => 'Bail out! xxx';
            call event       => T();
            call terminate   => 255;
            call causes_fail => 1;
        },
        "Got bail with details"
    );
};

subtest parse_tap_ok => sub {
    my $one = bless {}, $CLASS;

    like(
        $one->parse_tap_ok('ok'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "Simple ok"
    );

    like(
        $one->parse_tap_ok('not ok'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "Nameless Assertion";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "Simple not ok"
    );

    like(
        $one->parse_tap_ok('ok 1'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "simple ok with number"
    );

    like(
        $one->parse_tap_ok('not ok 1'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "Nameless Assertion";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "simple not ok with number"
    );

    like(
        $one->parse_tap_ok('ok foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "foo";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "Simple ok with name"
    );

    like(
        $one->parse_tap_ok('not ok foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "foo";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "Simple named not ok"
    );

    like(
        $one->parse_tap_ok('ok 1 foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "foo";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "named ok with number"
    );

    like(
        $one->parse_tap_ok('not ok 1 foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "foo";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "named not ok with number"
    );

    like(
        $one->parse_tap_ok('ok 1 - foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "foo";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "named ok with number and dash"
    );

    like(
        $one->parse_tap_ok('not ok 1 - foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "foo";
            call number           => 1;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "named ok with number and dash"
    );

    like(
        $one->parse_tap_ok('ok #tOdO'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => D();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "Simple todo"
    );

    like(
        $one->parse_tap_ok('not ok #todo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => D();
                field pass => F();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "simple not ok todo"
    );

    like(
        $one->parse_tap_ok('ok # todo foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => D();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "todo ok with reason"
    );

    like(
        $one->parse_tap_ok('not ok # todo foo'),
        object {
            call event => hash {
                field reason => DNE();
                field todo => D();
                field pass => F();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "todo not ok with reason"
    );

    like(
        $one->parse_tap_ok('ok #skip'),
        object {
            call event => hash {
                field reason => D();
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (SKIP)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "Simple skip"
    );

    like(
        $one->parse_tap_ok('not ok #sKiP'),
        object {
            call event => hash {
                field reason => D();
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "Nameless Assertion (SKIP)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "not ok skip"
    );

    like(
        $one->parse_tap_ok('ok # skip foo'),
        object {
            call event => hash {
                field reason => 'foo';
                field todo => DNE();
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (SKIP: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "ok skip with reason"
    );

    like(
        $one->parse_tap_ok('not ok # skip foo'),
        object {
            call event => hash {
                field reason => 'foo';
                field todo => DNE();
                field pass => F();
                field effective_pass => F();
            };

            call summary          => "Nameless Assertion (SKIP: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => T();
        },
        "not ok skip with reason"
    );

    like(
        $one->parse_tap_ok('ok # todo & skip foo'),
        object {
            call event => hash {
                field reason => 'foo';
                field todo => 'foo';
                field pass => T();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO: foo) (SKIP: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "todo and skip"
    );

    like(
        $one->parse_tap_ok('not ok # todo & skip foo'),
        object {
            call event => hash {
                field reason => 'foo';
                field todo => 'foo';
                field pass => F();
                field effective_pass => T();
            };

            call summary          => "Nameless Assertion (TODO: foo) (SKIP: foo)";
            call number           => undef;
            call increments_count => 1;
            call causes_fail      => F();
        },
        "not ok todo and skip"
    );

    like(
        [$one->parse_tap_ok('ok-foo')],
        array {
            item object {
                call event => hash {
                    field pass           => T();
                    field effective_pass => T();
                };

                call summary          => "foo";
                call number           => undef;
                call increments_count => 1;
                call causes_fail      => F();
            };
            item object {
                call parse_error => "'ok' is not immedietly followed by a space.";
            };
            end;
        },
        "Need a space after ok",
    );

    like(
        [$one->parse_tap_ok('ok  1 - foo')],
        array {
            item object {
                call event => hash {
                    field pass           => T();
                    field effective_pass => T();
                };

                call summary          => "foo";
                call number           => 1;
                call increments_count => 1;
                call causes_fail      => F();
            };
            item object {
                call parse_error => "Extra space after 'ok'";
            };
            end;
        },
        "Too much space",
    );

    like(
        [$one->parse_tap_ok('ok foo# todo')],
        array {
            item object {
                call event => hash {
                    field pass           => T();
                    field effective_pass => T();
                };

                call summary          => "foo (TODO)";
                call number           => undef;
                call increments_count => 1;
                call causes_fail      => F();
            };
            item object {
                call parse_error => "No space before the '#' for the 'todo' directive.";
            };
            end;
        },
        "No space before directive",
    );

    like(
        [$one->parse_tap_ok('ok foo # todo-xxx')],
        array {
            item object {
                call event => hash {
                    field pass           => T();
                    field effective_pass => T();
                };

                call summary          => "foo (TODO: -xxx)";
                call number           => undef;
                call increments_count => 1;
                call causes_fail      => F();
            };
            item object {
                call parse_error => "No space between 'todo' directive and reason.";
            };
            end;
        },
        "No space after directive",
    );
};

subtest step => sub {
    my $m = mock $CLASS => (
        override => [
            parse_stdout => sub { 'stdout1', 'stdout2' },
            parse_stderr => sub { 'stderr1', 'stderr2' },
        ],
    );
    my $one = bless {}, $CLASS;

    is(
        [$one->step],
        [qw/stdout1 stdout2 stderr1 stderr2/],
        "Got facts from STDOUT and STDERR"
    );
};

subtest strip_comment => sub {
    local *strip_comment = $CLASS->can('strip_comment');

    is(
        [strip_comment("        #    foo\n")],
        [2, "foo"],
        "Stripped comment, got message and nesting"
    );

    is(
        [strip_comment("        #    \n")],
        [2, ""],
        "Stripped comment, got empty message and nesting"
    );

    is(
        [strip_comment("#foo\n")],
        [0, "foo"],
        "compact case"
    );

    is(
        [strip_comment("  foo  \n")],
        [],
        "Not a comment"
    );
};

my (@stderr, @stdout, $done);
{
    package My::Proc;

    sub is_done { $done }

    sub get_err_line {
        my $self = shift;
        my %params = @_;

        return shift @stderr unless $params{peek};
        return $stderr[0];
    }

    sub get_out_line {
        my $self = shift;
        my %params = @_;

        return shift @stdout unless $params{peek};
        return $stdout[0];
    }
}

subtest slurp_comments => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = (
        "    # first\n",
        "    # second\n",
        "    # third\n",
        "# first\n",
        "# second\n",
        "# third\n",
    );

    is(
        $one->slurp_comments('STDOUT'),
        object {
            call event              => 1;
            call nested             => 1;
            call summary            => "first\nsecond\nthird";
            call parsed_from_string => "    # first\n    # second\n    # third\n";
            call parsed_from_handle => 'STDOUT';
            call diagnostics        => 0;
            call hide               => 0;
        },
        "Got multi-line comment"
    );

    is(
        $one->slurp_comments('STDOUT'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "first\nsecond\nthird";
            call parsed_from_string => "# first\n# second\n# third\n";
            call parsed_from_handle => 'STDOUT';
            call diagnostics        => 0;
            call hide               => 0;
        },
        "Got multi-line comment"
    );

    @stderr = (
        "# Failed test xxx\n",
        "# at line 123.\n",
        "# more diag for xxx\n",

        "# Failed test yyy at line 321.\n",
        "# more diag for yyy\n",
    );

    is(
        $one->slurp_comments('STDERR'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "Failed test xxx\nat line 123.";
            call parsed_from_string => "# Failed test xxx\n# at line 123.\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "Grouped failure output"
    );

    is(
        $one->slurp_comments('STDERR'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "more diag for xxx";
            call parsed_from_string => "# more diag for xxx\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "Extra diag"
    );


    is(
        $one->slurp_comments('STDERR'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "Failed test yyy at line 321.";
            call parsed_from_string => "# Failed test yyy at line 321.\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "Isolated failure output"
    );


    is(
        $one->slurp_comments('STDERR'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "more diag for yyy";
            call parsed_from_string => "# more diag for yyy\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "final diag"
    );

    @stderr = ("#\n");
    is(
        $one->slurp_comments('STDERR'),
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "no summary";
            call parsed_from_string => "#\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 1;
        },
        "Invisible diag"
    );
};

subtest parse_stderr => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stderr = (
        "random stderr\n",

        "# Failed test xxx\n",
        "# at line 123.\n",
        "# more diag for xxx\n",

        "random stderr\n",
    );

    is(
        $one->parse_stderr,
        object {
            call nested             => 0;
            call summary            => "random stderr";
            call parsed_from_string => "random stderr\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "First stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "Failed test xxx\nat line 123.";
            call parsed_from_string => "# Failed test xxx\n# at line 123.\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "Failure stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call event              => 1;
            call nested             => 0;
            call summary            => "more diag for xxx";
            call parsed_from_string => "# more diag for xxx\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
            call hide               => 0;
        },
        "diag stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call nested             => 0;
            call summary            => "random stderr";
            call parsed_from_string => "random stderr\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "More stderr"
    );

    is([$one->parse_stderr], [], "No more stderr");
};

subtest parse_stdout => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = map { "$_\n" } split /\n/, <<'    EOT';
ok 1 - pass
not ok 2 - fail
not ok 3 - todo # TODO because
ok 4 - skip # SKIP because
    ok 1 - subtest result a
    not ok 2 - subtest result b
    1..2
not ok 5 - subtest a ended
    ok 1 - subtest result a
    ok 2 - subtest result b
    1..2
ok 6 - subtest b ended
    ok 1 - subtest result a
        ok 1 - subtest result a
        ok 2 - subtest result b
        1..2
    ok 2 - inner subtest ended
    ok 3 - subtest result b
    1..3
ok 7 - outer subtest ended

# this is a note that
# spans a couple of
# lines. we want it to be a single
# note though to preserve rendering

not ok 8 - failing buffered subtest {
    ok 1 - subtest result a
    not ok 2 - subtest result b
    1..2
}

ok 9 - passing buffered subtest {
    ok 1 - subtest result a
    ok 2 - subtest result b
    1..2
}
ok 10 - outer buffered subtest {
    ok 1 - subtest result a
    ok 2 - nested buffered subtest {
        ok 1 - subtest result a
        ok 2 - subtest result b
        1..2
    }
    ok 3 - subtest result b
    1..3
}
1..10
    EOT

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'pass';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
            }
        ],
        "Pass event"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'fail';
                call causes_fail      => 1;
                call increments_count => 1;
                call number           => 2;
            }
        ],
        "Fail event"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'todo (TODO: because)';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 3;
            }
        ],
        "TODO event"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'skip (SKIP: because)';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 4;
            }
        ],
        "SKIP event"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'A';
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 1;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'A';
            }
        ],
        "Fail inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'A';
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest a ended';
                call causes_fail      => 1;
                call increments_count => 1;
                call number           => 5;
                call is_subtest       => 'A';
            }
        ],
        "Failing subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'B';
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'B';
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'B';
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest b ended';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 6;
                call is_subtest       => 'B';
            }
        ],
        "Passing subtest"
    );







    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'inner subtest ended';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call is_subtest       => 'D';
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Passing subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 3;
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 3 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 3, undef, undef ];
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'outer subtest ended';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 7;
                call is_subtest       => 'C';
                call nested           => 0;
            }
        ],
        "Passing subtest"
    );

    like(
        [$one->parse_stdout],
        [],
        "Empty space",
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => "this is a note that\nspans a couple of\nlines. we want it to be a single\nnote though to preserve rendering";
                call nested           => 0;
            }
        ],
        "Got a multi-line note"
    );

    like(
        [$one->parse_stdout],
        [],
        "Empty space",
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 1;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'failing buffered subtest';
                call causes_fail      => 1;
                call increments_count => 1;
                call number           => 8;
                call is_subtest       => 'E';
            },
        ],
        "Failing buffered subtest"
    );

    like(
        [$one->parse_stdout],
        [],
        "Empty space",
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'passing buffered subtest';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 9;
                call is_subtest       => 'F';
            },
        ],
        "Passing buffered subtest"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result a';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 1;
                call in_subtest       => 'I';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call in_subtest       => 'I';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 2, undef, undef ];
                call in_subtest       => 'I';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'nested buffered subtest';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 2;
                call is_subtest       => 'I';
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'subtest result b';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 3;
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 3 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 3, undef, undef ];
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'outer buffered subtest';
                call causes_fail      => 0;
                call increments_count => 1;
                call number           => 10;
                call is_subtest       => 'G';
                call nested           => 0;
            },
        ],
        "Nested buffered subtests"
    );

    like(
        [$one->parse_stdout],
        [
            object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 10 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call sets_plan        => [ 10, undef, undef ];
            }
        ],
        "Final Plan"
    );
};

subtest todo_subtest => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = map { "$_\n" } split /\n/, <<'    EOT';
not ok 1 - todo # TODO test todo {
    not ok 1 - fail
    # Failed test 'fail'
    # at test.pl line 9.
    1..1
}
    EOT

    like(
        [$one->parse_stdout],
        array {
            item object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'fail';
                call causes_fail      => T();
                call increments_count => T();
                call number           => 1;
                call nested           => 1;
                call in_subtest       => 'A';
            };
            item object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'Plan is 1 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call nested           => 1;
                call in_subtest       => 'A';
            };
            item object {
                prop blessed          => 'Test2::Harness::Fact';
                call event            => T();
                call summary          => 'todo (TODO: test todo)';
                call causes_fail      => F();
                call increments_count => T();
                call nested           => 0;
                call is_subtest       => 'A';
            };
        },
        "Buffered subtest with todo before opening curly"
    );
};

done_testing;

__END__
