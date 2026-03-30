use Test2::V0 -target => 'Test2::Harness::Collector::TapParser';

BEGIN {
    CLASS()->import(qw/parse_stdout_tap parse_stderr_tap parse_tap_line/);
}

subtest parse_stdout_tap_ok => sub {
    my $result = parse_stdout_tap("ok 1 - test passes");
    ok($result, "got result from ok line");
    ok($result->{assert}{pass}, "assertion passes");
    is($result->{from_tap}{source}, 'STDOUT', "source is STDOUT");
    is($result->{from_tap}{details}, "ok 1 - test passes", "details preserved");
};

subtest parse_stdout_tap_not_ok => sub {
    my $result = parse_stdout_tap("not ok 1 - test fails");
    ok($result, "got result from not ok line");
    ok(!$result->{assert}{pass}, "assertion fails");
    is($result->{from_tap}{source}, 'STDOUT', "source is STDOUT");
};

subtest parse_stdout_tap_plan => sub {
    my $result = parse_stdout_tap("1..5");
    ok($result, "got result from plan line");
    is($result->{plan}{count}, 5, "plan count is 5");
    is($result->{from_tap}{source}, 'STDOUT', "source is STDOUT");
};

subtest parse_stdout_tap_no_match => sub {
    my $result = parse_stdout_tap("some random text");
    ok(!$result, "no result for non-TAP line");
};

subtest parse_stderr_tap_comment => sub {
    my $result = parse_stderr_tap("# some diagnostic");
    ok($result, "got result for stderr comment");
    is($result->{from_tap}{source}, 'STDERR', "source is STDERR");
    is($result->{info}[-1]{tag}, 'DIAG', "tag is DIAG");
    ok($result->{info}[-1]{debug}, "debug flag set");
};

subtest parse_stderr_tap_non_comment => sub {
    my $result = parse_stderr_tap("some random text");
    ok(!$result, "no result for non-comment stderr line");
};

subtest parse_stderr_tap_indented_comment => sub {
    my $result = parse_stderr_tap("    # indented diag");
    ok($result, "got result for indented stderr comment");
    is($result->{from_tap}{source}, 'STDERR', "source is STDERR");
};

subtest parse_tap_line_ok => sub {
    my $result = parse_tap_line("ok 1");
    ok($result, "got result from 'ok 1'");
    ok($result->{assert}{pass}, "assertion passes");
    is($result->{assert}{number}, 1, "number is 1");
    is($result->{trace}{nested}, 0, "nested level is 0");
};

subtest parse_tap_line_not_ok => sub {
    my $result = parse_tap_line("not ok 1 - expected failure");
    ok($result, "got result from 'not ok' line");
    ok(!$result->{assert}{pass}, "assertion fails");
    is($result->{assert}{details}, "expected failure", "details preserved");
};

subtest parse_tap_line_plan => sub {
    my $result = parse_tap_line("1..3");
    ok($result, "got result from plan");
    is($result->{plan}{count}, 3, "plan count is 3");
    ok(!$result->{plan}{skip}, "not a skip plan");
    is($result->{trace}{nested}, 0, "nested level is 0");
    is($result->{hubs}[0]{nested}, 0, "hub nested level is 0");
};

subtest parse_tap_line_skip_all => sub {
    my $result = parse_tap_line("1..0 # SKIP no tests");
    ok($result, "got result from skip-all plan");
    is($result->{plan}{count}, 0, "plan count is 0");
    ok($result->{plan}{skip}, "is a skip plan");
    is($result->{plan}{details}, "no tests", "reason preserved");
};

subtest parse_tap_line_comment => sub {
    my $result = parse_tap_line("# a comment");
    ok($result, "got result from comment line");
    is($result->{info}[0]{tag}, 'NOTE', "tag is NOTE");
    is($result->{info}[0]{details}, "a comment", "comment text extracted");
    ok(!$result->{info}[0]{debug}, "not debug for stdout comment");
};

subtest parse_tap_line_bail => sub {
    my $result = parse_tap_line("Bail out! something went wrong");
    ok($result, "got result from bail line");
    ok($result->{control}{halt}, "halt is set");
    is($result->{control}{details}, "something went wrong", "bail reason preserved");
};

subtest parse_tap_line_version => sub {
    my $result = parse_tap_line("TAP version 13");
    ok($result, "got result from version line");
    is($result->{info}[0]{tag}, 'INFO', "info tag is INFO");
};

subtest parse_tap_line_nested => sub {
    my $result = parse_tap_line("    ok 1 - nested");
    ok($result, "got result from nested ok line");
    is($result->{trace}{nested}, 1, "nested level is 1");
    is($result->{hubs}[0]{nested}, 1, "hub nested level is 1");
};

subtest parse_tap_line_deep_nested => sub {
    my $result = parse_tap_line("        ok 1 - deep nested");
    ok($result, "got result from deep nested ok line");
    is($result->{trace}{nested}, 2, "nested level is 2");
};

subtest parse_tap_line_non_tap => sub {
    my $result = parse_tap_line("random text with no TAP meaning");
    ok(!defined $result, "returns undef for non-TAP line");
};

subtest parse_tap_ok_with_todo => sub {
    my $result = parse_tap_line("not ok 1 - todo item # TODO fix later");
    ok($result, "got result from todo line");
    ok(!$result->{assert}{pass}, "assertion fails");
    my $amnesty = $result->{amnesty};
    ok($amnesty && @$amnesty, "has amnesty");
    my ($todo) = grep { $_->{tag} eq 'TODO' } @$amnesty;
    ok($todo, "found TODO amnesty");
    is($todo->{details}, "fix later", "todo reason preserved");
};

subtest parse_tap_ok_with_skip => sub {
    my $result = parse_tap_line("ok 1 # SKIP not implemented yet");
    ok($result, "got result from skip line");
    my $amnesty = $result->{amnesty};
    ok($amnesty && @$amnesty, "has amnesty");
    my ($skip) = grep { $_->{tag} eq 'SKIP' } @$amnesty;
    ok($skip, "found SKIP amnesty");
    is($skip->{details}, "not implemented yet", "skip reason preserved");
};

subtest parse_tap_buffered_subtest_end => sub {
    my $result = parse_tap_line("}");
    ok($result, "got result from closing brace");
    ok($result->{harness}{subtest_end}, "subtest_end is set");
};

subtest parse_tap_buffered_subtest_start => sub {
    my $result = parse_tap_line("ok 1 - my subtest {");
    ok($result, "got result from subtest start");
    ok($result->{harness}{subtest_start}, "subtest_start is set");
    ok($result->{parent}, "has parent facet");
};

done_testing;
