use Test2::V0;
use v5.38;

use App::Yath2::Renderer::Text::EventPainter;

# parse_facet turns one (facet-name, facet-item) pair into a render-meta hash
# describing how to paint it, or undef when the facet is not renderable.

my $p = App::Yath2::Renderer::Text::EventPainter->new;

subtest passing_assert => sub {
    my $m = $p->parse_facet(assert => {pass => 1, details => 'it works'});
    is($m->{key},       'PASS', "PASS key");
    is($m->{assert},    1,      "marked assert");
    is($m->{fail},      0,      "not a failure");
    is($m->{verbosity}, 1,      "always shown");
    is($m->{text},      'it works', "carries the assertion name");
};

subtest failing_assert => sub {
    my $m = $p->parse_facet(assert => {pass => 0, details => 'broke'});
    is($m->{key},  'FAIL', "FAIL key");
    is($m->{fail}, 1,      "is a failure");
};

subtest unnamed_assert => sub {
    my $m = $p->parse_facet(assert => {pass => 1});
    like($m->{text}, qr/UNNAMED/, "unnamed assertion gets a placeholder");
};

subtest info_note_vs_diag => sub {
    my $note = $p->parse_facet(info => {tag => 'NOTE', details => "a note"});
    is($note->{key},  'NOTE', "NOTE key");
    is($note->{diag}, 0,      "note is not diagnostic");

    my $diag = $p->parse_facet(info => {tag => 'DIAG', details => "a diag"});
    is($diag->{key},  'DIAG', "DIAG key");
    is($diag->{diag}, 1,      "diag is diagnostic");

    my $err = $p->parse_facet(info => {tag => 'STDERR', details => "err", debug => 1});
    is($err->{diag}, 1, "stderr is diagnostic");
};

subtest errors_facet => sub {
    my $m = $p->parse_facet(errors => {tag => 'ERROR', details => 'bad', fail => 1});
    is($m->{key},  'ERROR', "ERROR key");
    is($m->{fail}, 1,       "failing error");
    my $d = $p->parse_facet(errors => {details => 'noisy'});
    is($d->{key}, 'ERROR', "defaults to ERROR tag");
};

subtest plan_is_verbose_only => sub {
    my $m = $p->parse_facet(plan => {count => 3});
    is($m->{verbosity}, 2, "plan only shows in verbose mode");
    like($m->{text}, qr/3/, "mentions the count");
};

subtest multiline_text_meta => sub {
    my $m = $p->parse_facet(info => {tag => 'NOTE', details => "a\nbb\nc"});
    is($m->{multiline}, 1, "multi-line detected");
    is($m->{max_width}, 2, "widest line width reported");
};

subtest non_renderable_returns_undef => sub {
    is($p->parse_facet(hubs => [{nested => 0}]), undef, "structural-only facet not rendered");
    is($p->parse_facet(about => {package => 'X'}), undef, "about not rendered by default");
};

done_testing;
