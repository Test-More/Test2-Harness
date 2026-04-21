use Test2::V0;

use Test2::Harness2::Collector::Parser::TapParser qw{
    parse_stdout_tap
    parse_stderr_tap
    parse_tap_line
};

subtest 'parse_tap_line - plan' => sub {
    my $fd = parse_tap_line('1..3');
    ok($fd, "parsed plan");
    is($fd->{plan}{count}, 3,    "count is 3");
    is($fd->{plan}{skip},  0,    "not a skip");
    is($fd->{trace}{nested}, 0,  "not nested");
};

subtest 'parse_tap_line - skip plan' => sub {
    my $fd = parse_tap_line('1..0 # SKIP no reason');
    ok($fd, "parsed skip plan");
    is($fd->{plan}{count}, 0, "count is 0");
    is($fd->{plan}{skip},  1, "marked skip");
    like($fd->{plan}{details}, qr/no reason/, "reason captured");
};

subtest 'parse_tap_line - ok' => sub {
    my $fd = parse_tap_line('ok 1 - passes');
    ok($fd, "parsed ok");
    is($fd->{assert}{pass},    1,         "pass");
    is($fd->{assert}{number},  1,         "number");
    is($fd->{assert}{details}, 'passes',  "name extracted");
};

subtest 'parse_tap_line - not ok' => sub {
    my $fd = parse_tap_line('not ok 2 - oh no');
    is($fd->{assert}{pass},    F(),      "not pass");
    is($fd->{assert}{number},  2,        "number");
    is($fd->{assert}{details}, 'oh no',  "details");
};

subtest 'parse_tap_line - ok with TODO directive' => sub {
    my $fd = parse_tap_line('not ok 3 - broken # TODO fix later');
    is($fd->{assert}{pass}, F(), "not pass");
    my ($todo) = grep { $_->{tag} eq 'TODO' } @{$fd->{amnesty} // []};
    ok($todo, "got TODO amnesty");
    like($todo->{details}, qr/fix later/, "todo reason captured");
};

subtest 'parse_tap_line - ok with SKIP directive' => sub {
    my $fd = parse_tap_line('ok 4 # SKIP reasons');
    my ($skip) = grep { $_->{tag} eq 'SKIP' } @{$fd->{amnesty} // []};
    ok($skip, "got SKIP amnesty");
    like($skip->{details}, qr/reasons/, "skip reason captured");
};

subtest 'parse_tap_line - subtest start/end' => sub {
    my $start = parse_tap_line('ok 1 - Subtest: inner {');
    ok($start->{harness}{subtest_start}, "subtest start flagged");
    ok($start->{parent}, "parent facet present");

    my $end = parse_tap_line('}');
    ok($end->{harness}{subtest_end}, "subtest end flagged");
};

subtest 'parse_tap_line - bail out' => sub {
    my $fd = parse_tap_line('Bail out! catastrophic');
    ok($fd->{control}{halt}, "halt set");
    like($fd->{control}{details}, qr/catastrophic/, "bail message captured");
};

subtest 'parse_tap_line - comment becomes NOTE' => sub {
    my $fd = parse_tap_line('# just a note');
    is($fd->{info}[0]{tag},     'NOTE',        "tag");
    is($fd->{info}[0]{debug},   0,             "not debug");
    like($fd->{info}[0]{details}, qr/just a note/, "details");
};

subtest 'parse_tap_line - version' => sub {
    my $fd = parse_tap_line('TAP version 13');
    like($fd->{about}{details}, qr/TAP version 13/, "about");
    is($fd->{info}[0]{tag}, 'INFO', "info tag");
};

subtest 'parse_tap_line - non-TAP line returns undef' => sub {
    is(parse_tap_line('hello world'), undef, "non-tap line");
    is(parse_tap_line('random garbage'), undef, "garbage");
};

subtest 'parse_tap_line - nested indentation' => sub {
    my $fd = parse_tap_line('    ok 1 - inner');
    is($fd->{trace}{nested},    1, "nested=1");
    is($fd->{hubs}[0]{nested},  1, "hubs nested=1");

    $fd = parse_tap_line('        ok 1 - deeper');
    is($fd->{trace}{nested}, 2, "nested=2");

    # 3-space indent -> undef (not a multiple of 4)
    is(parse_tap_line('   ok 1'), undef, "3-space indent rejected");
};

subtest 'parse_stdout_tap - adds from_tap STDOUT' => sub {
    my $fd = parse_stdout_tap('ok 1 - x');
    ok($fd, "parsed");
    is($fd->{from_tap}{source},  'STDOUT', "source STDOUT");
    is($fd->{from_tap}{details}, 'ok 1 - x', "details preserved");

    is(parse_stdout_tap('not tap at all'), undef, "non-tap undef");
};

subtest 'parse_stderr_tap - only comments' => sub {
    my $fd = parse_stderr_tap('# diag line');
    ok($fd, "parsed comment");
    is($fd->{from_tap}{source}, 'STDERR', "source STDERR");
    is($fd->{info}[-1]{tag},    'DIAG',   "tag DIAG");
    is($fd->{info}[-1]{debug},  1,        "debug=1");

    is(parse_stderr_tap('ok 1 - not allowed'), undef, "non-comment undef");
    is(parse_stderr_tap('random error'),       undef, "random undef");
};

done_testing;
