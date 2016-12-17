use Test2::Bundle::Extended -target => 'Test2::Harness::Parser::TAP';

isa_ok($CLASS, 'Test2::Harness::Parser');
can_ok($CLASS, qw/_subtest_state/);

subtest morph => sub {
    my $one = bless {}, $CLASS;
    $one->morph;

    isa_ok(
        $one->_subtest_state,
        ['Test2::Harness::Parser::TAP::SubtestState'],
        "Morph set some defaults"
    );
};

subtest parse_tap_version => sub {
    my $one = bless {}, $CLASS;

    ok(!$one->parse_tap_version("ok", 0), "Not a version");

    like(
        $one->parse_tap_version('TAP version 13', 0),
        object { call summary => 'TAP version 13' },
        'Parsed version'
    );

    like(
        $one->parse_tap_version('TAP version 55.5', 0),
        object { call summary => 'TAP version 55.5' },
        'Parsed version'
    );
};

subtest parse_tap_plan => sub {
    my $one = bless {}, $CLASS;

    ok(!$one->parse_tap_plan('0..1', 0), "not a plan 0..1");
    ok(!$one->parse_tap_plan('foo',  0), "not a plan foo");

    like(
        $one->parse_tap_plan('1..5', 0),
        object {
            call summary => 'Plan is 5 assertions';
            call_list sets_plan => [5, '', undef];
        },
        "Got simple plan"
    );

    like(
        $one->parse_tap_plan('1..0', 0),
        object {
            call summary => "Plan is 'SKIP', no reason given";
            call_list sets_plan => [0, 'SKIP', 'no reason given'];
        },
        "Got simple skip"
    );

    like(
        $one->parse_tap_plan('1..0 # SkIp foo', 0),
        object {
            call summary => "Plan is 'SKIP', foo";
            call_list sets_plan => [0, 'SKIP', 'foo'];
        },
        "Got skip with reason"
    );

    like(
        [$one->parse_tap_plan('1..0 xxx', 0)],
        [
            object {
                call summary => "Plan is 'SKIP', no reason given";
                call_list sets_plan => [0, 'SKIP', 'no reason given'];
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
    ok(!$one->parse_tap_bail('ok', 0), "not a bailout");

    like(
        $one->parse_tap_bail('Bail out!', 0),
        object {
            call summary     => 'Bail out!';
            call terminate   => 255;
            call causes_fail => 1;
        },
        "Got bail"
    );

    like(
        $one->parse_tap_bail('Bail out! xxx', 0),
        object {
            call summary     => 'Bail out!  xxx';
            call terminate   => 255;
            call causes_fail => 1;
        },
        "Got bail with details"
    );
};

subtest parse_tap_ok => sub {
    my $one = bless {}, $CLASS;

    like(
        [$one->parse_tap_ok('ok', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "Simple ok"
    );

    like(
        [$one->parse_tap_ok('not ok', 0)],
        array {
            item object {
                call pass             => F();
                call effective_pass   => F();
                call summary          => "Nameless Assertion";
                call increments_count => T();
                call causes_fail      => T();
                end;
            }
        },
        "Simple not ok"
    );

    like(
        [$one->parse_tap_ok('ok 1', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "simple ok with number"
    );

    like(
        [$one->parse_tap_ok('not ok 1', 0)],
        array {
            item object {
                call pass             => F();
                call effective_pass   => F();
                call summary          => "Nameless Assertion";
                call increments_count => T();
                call causes_fail      => T();
                end;
            }
        },
        "simple not ok with number"
    );

    like(
        [$one->parse_tap_ok('ok foo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "Simple ok with name"
    );

    like(
        [$one->parse_tap_ok('not ok foo', 0)],
        array {
            item object {
                call pass             => F();
                call effective_pass   => F();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => T();
                end;
            }
        },
        "Simple named not ok"
    );

    like(
        [$one->parse_tap_ok('ok 1 foo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "named ok with number"
    );

    like(
        [$one->parse_tap_ok('not ok 1 foo', 0)],
        array {
            item object {
                call pass             => F();
                call effective_pass   => F();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => T();
                end;
            }
        },
        "named not ok with number"
    );

    like(
        [$one->parse_tap_ok('ok 1 - foo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "named ok with number and dash"
    );

    like(
        [$one->parse_tap_ok('not ok 1 - foo', 0)],
        array {
            item object {
                call pass             => F();
                call effective_pass   => F();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => T();
                end;
            }
        },
        "named ok with number and dash"
    );

    like(
        [$one->parse_tap_ok('ok #tOdO', 0)],
        array {
            item object {
                call reason           => DNE();
                call todo             => D();
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (TODO)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "Simple todo"
    );

    like(
        [$one->parse_tap_ok('not ok #todo', 0)],
        array {
            item object {
                call reason           => DNE();
                call todo             => D();
                call pass             => F();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (TODO)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "simple not ok todo"
    );

    like(
        [$one->parse_tap_ok('ok # todo foo', 0)],
        array {
            item object {
                call reason           => DNE();
                call todo             => D();
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (TODO: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "todo ok with reason"
    );

    like(
        [$one->parse_tap_ok('not ok # todo foo', 0)],
        array {
            item object {
                call reason           => DNE();
                call todo             => D();
                call pass             => F();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (TODO: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "todo not ok with reason"
    );

    like(
        [$one->parse_tap_ok('ok #skip', 0)],
        array {
            item object {
                call reason           => D();
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "Simple skip"
    );

    like(
        [$one->parse_tap_ok('not ok #sKiP', 0)],
        array {
            item object {
                call reason           => D();
                call pass             => F();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "not ok skip"
    );

    like(
        [$one->parse_tap_ok('ok # skip foo', 0)],
        array {
            item object {
                call reason           => 'foo';
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "ok skip with reason"
    );

    like(
        [$one->parse_tap_ok('not ok # skip foo', 0)],
        array {
            item object {
                call reason           => 'foo';
                call pass             => F();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "not ok skip with reason"
    );

    like(
        [$one->parse_tap_ok('ok # todo & skip foo', 0)],
        array {
            item object {
                call reason           => 'foo';
                call pass             => T();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "todo and skip"
    );

    like(
        [$one->parse_tap_ok('not ok # todo & skip foo', 0)],
        array {
            item object {
                call reason           => 'foo';
                call pass             => F();
                call effective_pass   => T();
                call summary          => "Nameless Assertion (SKIP: foo)";
                call increments_count => T();
                call causes_fail      => F();
                end;
            }
        },
        "not ok todo and skip"
    );

    like(
        [$one->parse_tap_ok('ok-foo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo";
                call increments_count => T();
                call causes_fail      => F();
            };
            item object {
                call parse_error => "'ok' is not immediately followed by a space.";
            };
            end;
        },
        "Need a space after ok",
    );

    like(
        [$one->parse_tap_ok('ok  1 - foo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo";
                call increments_count => T();
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
        [$one->parse_tap_ok('ok foo# todo', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo (TODO)";
                call increments_count => T();
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
        [$one->parse_tap_ok('ok foo # todo-xxx', 0)],
        array {
            item object {
                call pass             => T();
                call effective_pass   => T();
                call summary          => "foo (TODO: -xxx)";
                call increments_count => T();
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

my (@stderr, @stdout, $done);
{

    package My::Proc;

    sub is_done { $done }

    sub get_err_line {
        my $self   = shift;
        my %params = @_;

        return shift @stderr unless $params{peek};
        return $stderr[0];
    }

    sub get_out_line {
        my $self   = shift;
        my %params = @_;

        return shift @stdout unless $params{peek};
        return $stdout[0];
    }
}

subtest step => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);
    @stdout = (
        "ok 1 foo\n",
        "ok 2 bar\n",
    );
    @stderr = (
        "# foo\n",
        "# bar\n",
    );

    like(
        [$one->step],
        array {
            item object {
                prop blessed => 'Test2::Event::Ok';
                call name    => 'foo';
            };
            item object {
                prop blessed => 'Test2::Event::Diag';
                call message => "foo\nbar";
            };
            end;
        },
        "Got facts from STDOUT and STDERR"
    );
};

subtest strip_comment => sub {
    local *strip_comment = $CLASS->can('strip_comment');

    is(
        [strip_comment("        #    foo\n")],
        [2, "   foo"],
        "Stripped comment, got message and nesting"
    );

    is(
        [strip_comment("        #    \n")],
        [2, "   "],
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
            call nested      => 1;
            call summary     => "first\nsecond\nthird";
            call diagnostics => F();
        },
        "Got multi-line comment"
    );

    is(
        $one->slurp_comments('STDOUT'),
        object {
            call nested      => 0;
            call summary     => "first\nsecond\nthird";
            call diagnostics => F();
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
            call nested      => 0;
            call summary     => "Failed test xxx\nat line 123.";
            call diagnostics => 1;
        },
        "Grouped failure output"
    );

    is(
        $one->slurp_comments('STDERR'),
        object {
            call nested      => 0;
            call summary     => "more diag for xxx";
            call diagnostics => 1;
        },
        "Extra diag"
    );

    is(
        $one->slurp_comments('STDERR'),
        object {
            call nested      => 0;
            call summary     => "Failed test yyy at line 321.";
            call diagnostics => 1;
        },
        "Isolated failure output"
    );

    is(
        $one->slurp_comments('STDERR'),
        object {
            call nested      => 0;
            call summary     => "more diag for yyy";
            call diagnostics => 1;
        },
        "final diag"
    );

    @stderr = ("#\n");
    is(
        $one->slurp_comments('STDERR'),
        object {
            call nested      => 0;
            call summary     => '';
            call diagnostics => 1;
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
            prop blessed     => 'Test2::Event::UnknownStderr';
            call summary     => "random stderr";
            call diagnostics => 1;
        },
        "First stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call nested      => 0;
            call summary     => "Failed test xxx\nat line 123.";
            call diagnostics => 1;
        },
        "Failure stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call nested      => 0;
            call summary     => "more diag for xxx";
            call diagnostics => 1;
        },
        "diag stderr"
    );

    is(
        $one->parse_stderr,
        object {
            prop blessed     => 'Test2::Event::UnknownStderr';
            call summary     => "random stderr";
            call diagnostics => 1;
        },
        "More stderr"
    );

    is([$one->parse_stderr], [], "No more stderr");
};

subtest parse_stdout => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = map { "$_\n" } split /\n/, <<'    EOT';
ok 1 - pass
# this note has no leading whitespace
not ok 2 - fail
#     this note has significant leading whitespace
not ok 3 - todo # TODO because
ok 4 - skip # SKIP because
    ok 1 - subtest result 1.1
    not ok 2 - subtest result 1.2
    1..2
not ok 5 - Subtest: subtest a ended
    ok 1 - subtest result 2.1
    ok 2 - subtest result 2.2
    1..2
ok 6 - Subtest: subtest b ended
    ok 1 - subtest result 3.1
        ok 1 - subtest result 3.2.1
        ok 2 - subtest result 3.2.2
        1..2
    ok 2 - Subtest: inner subtest ended
    ok 3 - subtest result 3.3
    1..3
ok 7 - Subtest: outer subtest ended

# this is a note that
# spans a couple of
# lines. we want it to be a single
# note though to preserve rendering

not ok 8 - failing buffered subtest {
    ok 1 - subtest result 4.1
    not ok 2 - subtest result 4.2
    1..2
}

ok 9 - passing buffered subtest {
    ok 1 - subtest result 5.1
    ok 2 - subtest result 5.2
    1..2
}
ok 10 - outer buffered subtest {
    ok 1 - subtest result 6.1
    ok 2 - nested buffered subtest {
        ok 1 - subtest result 6.2.1
        ok 2 - subtest result 6.2.2
        1..2
    }
    ok 3 - subtest result 6.3
    1..3
}
1..10
    EOT

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'pass';
                call causes_fail      => F();
                call increments_count => T();
            }
        ],
        "Pass event"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed => 'Test2::Event::Note';
                call summary => 'this note has no leading whitespace';
                call nested  => 0;
            }
        ],
        "Got a note with no leading whitespace"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'fail';
                call causes_fail      => 1;
                call increments_count => T();
            }
        ],
        "Fail event"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed => 'Test2::Event::Note';
                call summary => '    this note has significant leading whitespace';
                call nested  => 0;
            }
        ],
        "Got a note with significant leading whitespace"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'todo (TODO: because)';
                call causes_fail      => F();
                call increments_count => T();
            }
        ],
        "TODO event"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Skip';
                call summary          => 'skip (SKIP: because)';
                call causes_fail      => F();
                call increments_count => T();
            }
        ],
        "SKIP event"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 1.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'A';
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 1.2';
                call causes_fail      => 1;
                call increments_count => T();
                call in_subtest       => 'A';
            }
        ],
        "Fail inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'A';
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'Subtest: subtest a ended';
                call causes_fail      => 1;
                call increments_count => T();
                call subtest_id       => 'A';
            }
        ],
        "Failing subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 2.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'B';
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 2.2';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'B';
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'B';
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'Subtest: subtest b ended';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'B';
            }
        ],
        "Passing subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 3.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 3.2.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Pass inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 3.2.2';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'D';
                call nested           => 2;
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'Subtest: inner subtest ended';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'D';
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Passing subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 3.3';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Pass gain inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 3 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [3, '', undef];
                call in_subtest       => 'C';
                call nested           => 1;
            }
        ],
        "Plan inside subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'Subtest: outer subtest ended';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'C';
                call nested           => 0;
            }
        ],
        "Passing subtest"
    );

    like(
        [$one->step],
        [],
        "Empty space",
    );

    like(
        [$one->step],
        [
            object {
                prop blessed => 'Test2::Event::Note';
                call summary => "this is a note that\nspans a couple of\nlines. we want it to be a single\nnote though to preserve rendering";
                call nested  => 0;
            }
        ],
        "Got a multi-line note"
    );

    like(
        [$one->step],
        [],
        "Empty space",
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 4.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 4.2';
                call causes_fail      => 1;
                call increments_count => T();
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'E';
            },
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'failing buffered subtest';
                call causes_fail      => 1;
                call increments_count => T();
                call subtest_id       => 'E';
            },
        ],
        "Failing buffered subtest"
    );

    like(
        [$one->step],
        [],
        "Empty space",
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 5.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 5.2';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'F';
            },
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'passing buffered subtest';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'F';
            },
        ],
        "Passing buffered subtest"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 6.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 6.2.1';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'H';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 6.2.2';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'H';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 2 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [2, '', undef];
                call in_subtest       => 'H';
                call nested           => 2;
            },
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'nested buffered subtest';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'H';
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'subtest result 6.3';
                call causes_fail      => F();
                call increments_count => T();
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 3 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [3, '', undef];
                call in_subtest       => 'G';
                call nested           => 1;
            },
            object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'outer buffered subtest';
                call causes_fail      => F();
                call increments_count => T();
                call subtest_id       => 'G';
                call nested           => 0;
            },
        ],
        "Nested buffered subtests"
    );

    like(
        [$one->step],
        [
            object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 10 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call_list sets_plan   => [10, '', undef];
            }
        ],
        "Final Plan"
    );
};

subtest todo_subtest => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = map { "$_\n" } split /\n/, <<'    EOT';
not ok 1 - st-todo # TODO test todo {
    not ok 1 - fail
    # Failed test 'fail'
    # at test.pl line 9.
    1..1
}
    EOT

    like(
        [$one->step],
        array {
            item object {
                prop blessed          => 'Test2::Event::Ok';
                call summary          => 'fail';
                call causes_fail      => F();
                call increments_count => T();
                call nested           => 1;
                call in_subtest       => 'A';
            };
            item object {
                prop blessed          => 'Test2::Event::Plan';
                call summary          => 'Plan is 1 assertions';
                call causes_fail      => F();
                call increments_count => F();
                call nested           => 1;
                call in_subtest       => 'A';
            };
            item object {
                prop blessed          => 'Test2::Event::Subtest';
                call summary          => 'st-todo (TODO: test todo)';
                call causes_fail      => F();
                call increments_count => T();
                call nested           => 0;
                call subtest_id       => 'A';
            };
        },
        "Buffered subtest with todo before opening curly"
    );
};

done_testing;

__END__
