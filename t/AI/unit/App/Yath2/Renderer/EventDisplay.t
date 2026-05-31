use Test2::V0;
use v5.38;

use App::Yath2::Renderer::EventDisplay;

# EventDisplay deduces per-facet render metadata and display order from an event,
# with no presentation decisions.

my $f = App::Yath2::Renderer::EventDisplay->new;

subtest passing_assert => sub {
    my $m = $f->parse_facet(assert => {pass => 1, details => 'it works'});
    is($m->{facet},     'assert', "carries the facet name");
    is($m->{key},       'PASS',   "PASS key");
    is($m->{assert},    1,        "marked assert");
    is($m->{fail},      0,        "not a failure");
    is($m->{verbosity}, 1,        "always shown");
    is($m->{text},      'it works', "carries the assertion name");
};

subtest failing_assert => sub {
    my $m = $f->parse_facet(assert => {pass => 0, details => 'broke'});
    is($m->{key},  'FAIL', "FAIL key");
    is($m->{fail}, 1,      "is a failure");
};

subtest unnamed_assert => sub {
    my $m = $f->parse_facet(assert => {pass => 1});
    like($m->{text}, qr/UNNAMED/, "unnamed assertion gets a placeholder");
};

subtest info_note_vs_diag => sub {
    my $note = $f->parse_facet(info => {tag => 'NOTE', details => "a note"});
    is($note->{key},  'NOTE', "NOTE key");
    is($note->{diag}, 0,      "note is not diagnostic");

    my $diag = $f->parse_facet(info => {tag => 'DIAG', details => "a diag"});
    is($diag->{key},  'DIAG', "DIAG key");
    is($diag->{diag}, 1,      "diag is diagnostic");

    my $err = $f->parse_facet(info => {tag => 'STDERR', details => "err", debug => 1});
    is($err->{diag}, 1, "stderr is diagnostic");
};

subtest errors_facet => sub {
    my $m = $f->parse_facet(errors => {tag => 'ERROR', details => 'bad', fail => 1});
    is($m->{key},  'ERROR', "ERROR key");
    is($m->{fail}, 1,       "failing error");
    my $d = $f->parse_facet(errors => {details => 'noisy'});
    is($d->{key}, 'ERROR', "defaults to ERROR tag");
};

subtest plan_is_verbose_only => sub {
    my $m = $f->parse_facet(plan => {count => 3});
    is($m->{verbosity}, 2, "plan only shows in verbose mode");
    like($m->{text}, qr/3/, "mentions the count");
};

subtest multiline_text_meta => sub {
    my $m = $f->parse_facet(info => {tag => 'NOTE', details => "a\nbb\nc"});
    is($m->{multiline}, 1, "multi-line detected");
    is($m->{max_width}, 2, "widest line width reported");
};

subtest trailing_newline_chomped => sub {
    my $m = $f->parse_facet(info => {tag => 'STDOUT', details => "one line\n"});
    is($m->{text}, "one line", "a single trailing newline is dropped");
};

subtest non_renderable_returns_undef => sub {
    is($f->parse_facet(hubs => [{nested => 0}]), undef, "structural-only facet not rendered");
    is($f->parse_facet(about => {package => 'X'}), undef, "about not rendered by default");
};

subtest facet_metas_order_and_filter => sub {
    my @metas = $f->facet_metas({
        assert => {pass => 1, details => 'a'},
        info   => [{tag => 'NOTE', details => 'n'}],
        plan   => {count => 1},
    });
    is([map { $_->{key} } @metas], ['PASS', 'NOTE'], "assert first, info last, plan hidden at verbosity 1");

    my @loud = $f->facet_metas({assert => {pass => 1, details => 'a'}, plan => {count => 1}}, verbosity => 2);
    is([map { $_->{key} } @loud], ['PASS', 'PLAN'], "plan shows at verbosity 2");
};

subtest facet_metas_amnesty_and_trace => sub {
    my @amn = $f->facet_metas({
        assert  => {pass => 0, details => 'todo'},
        amnesty => [{tag => 'TODO', details => 'later'}],
        trace   => {frame => ['main', 't.t', 1]},
    });
    is([map { $_->{key} } @amn], ['! PASS !'], "amnesty rewrites the assert key and suppresses debug");

    my @fail = $f->facet_metas({
        assert => {pass => 0, details => 'broke'},
        trace  => {frame => ['main', 't.t', 9]},
    });
    is([map { $_->{key} } @fail], ['FAIL', 'DEBUG'], "a failing assert turns trace into a debug meta");
};

subtest inspection_helpers => sub {
    my $st = {assert => {pass => 1, details => 's'}, parent => {children => [{assert => {pass => 1}}]}};
    ok($f->is_subtest($st), "is_subtest true for parent.children");
    is(scalar($f->subtest_children($st)), 1, "subtest_children returns the children");

    ok(!$f->is_subtest({assert => {pass => 1}}), "is_subtest false otherwise");

    ok($f->is_stray({harness_auditor => {stray => 1}, assert => {pass => 1}}), "is_stray true when marked");
    ok(!$f->is_stray({assert => {pass => 1}}), "is_stray false otherwise");

    # Unwraps a {facet_data=>...} event as well.
    is([$f->facet_metas({facet_data => {assert => {pass => 1, details => 'x'}}})]->[0]{text}, 'x', "unwraps a full event");
};

done_testing;
