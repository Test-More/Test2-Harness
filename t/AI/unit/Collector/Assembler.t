use Test2::V0;
use v5.38;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Assembler;

# The assembler coalesces scattered subtest events into one nested authoritative
# event per top-level subtest. Subtests reach it in two real shapes:
#
#   * Buffered (Stream2): Test2 core delivers the subtest already nested -- one
#     event whose parent.children hold the subtest's events. The assembler
#     passes it straight through.
#
#   * Streamed (TAP): the subtest open (ok ... {), its children, and the close
#     (}) arrive as SEPARATE events, each carrying a from_tap facet and a
#     nesting depth. The assembler buffers the children by depth and emits one
#     nested parent.children event when the subtest closes.
#
# Correlation is purely by nesting depth + arrival order; events carry no ids.
# (Stream2 never delivers a non-tap event at depth > 0 -- buffered subtests are
# pre-nested -- so the only depth-based assembly path is the TAP one, whose
# events always carry from_tap.)

sub ev ($fd) { return Test2::Harness2::Event->new(facet_data => $fd) }

# A TAP-streamed assertion line at a given depth (carries from_tap).
sub tap_assert ($pass, %e) {
    return {
        from_tap => {source => 'STDOUT', details => $e{name} // 'an assertion'},
        assert   => {pass => $pass ? 1 : 0, details => $e{name} // 'an assertion'},
        ($e{number} ? (assert => {pass => $pass ? 1 : 0, details => $e{name}, number => $e{number}}) : ()),
        trace    => {nested => $e{nested} // 0},
    };
}

# A TAP-streamed subtest open (ok NAME {) at a given depth.
sub tap_open ($name, $nested) {
    return {
        from_tap => {source => 'STDOUT', details => "ok - $name {"},
        harness  => {subtest_start => 1},
        parent   => {details => $name},
        assert   => {pass => 1, details => $name, number => 1},
        trace    => {nested => $nested},
    };
}

# A TAP-streamed subtest close (}) at a given depth.
sub tap_close ($nested) {
    return {
        from_tap => {source => 'STDOUT', details => '}'},
        harness  => {subtest_end => 1},
        parent   => {},
        trace    => {nested => $nested},
    };
}

# A plain depth-0 line that, by being shallower, closes any open subtest.
sub tap_plan ($count) {
    return {from_tap => {source => 'STDOUT', details => "1..$count"}, plan => {count => $count}, trace => {nested => 0}};
}

sub run ($assembler, @facets) {
    return map { $assembler->process_event(ev($_)) } @facets;
}

# Pull the one assembled top-level subtest event (carrying parent.children).
sub assembled (@events) {
    my ($e) = grep { $_->facet_data->{parent} && $_->facet_data->{parent}{children} } @events;
    return $e;
}

subtest does_processor_role => sub {
    ok(
        Test2::Harness2::Collector::Assembler->DOES('Test2::Harness2::Collector::Role::Processor'),
        "assembler consumes the Processor role",
    );
};

subtest passthrough_plain_events => sub {
    my $as  = Test2::Harness2::Collector::Assembler->new;
    my @out = run($as, {assert => {pass => 1, details => 'a plain assert'}, trace => {nested => 0}});
    is(scalar(@out), 1, "a plain top-level event passes straight through");
    is($out[0]->facet_data->{assert}{details}, 'a plain assert', "unchanged");
};

subtest buffered_stream2_passthrough => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # A buffered Stream2 subtest arrives already nested; hub marks it buffered.
    my $sub = {
        assert => {pass => 1, details => 'buffered st', number => 1},
        parent => {details => 'buffered st', children => [{assert => {pass => 1, details => 'kid'}}]},
        hubs   => [{nested => 0, buffered => 1}],
    };

    my @out = run($as, $sub);
    is(scalar(@out), 1, "already-buffered subtest passes straight through");
    ok($out[0]->facet_data->{parent}{children}, "children preserved");
};

subtest stream2_nested_info_suppressed => sub {
    # A nested Stream2 info event (note/diag, or a converted print) is folded
    # into its subtest's parent.children by Test2, so its realtime copy is
    # redundant: dropped by default, strayed when emit_stray is on. Event type
    # does not matter -- nesting alone makes it subtest-belonging.
    my $info = {info => [{tag => 'STDOUT', details => 'inside'}], trace => {nested => 1}};

    my @off = run(Test2::Harness2::Collector::Assembler->new, $info);
    is(scalar(@off), 0, "nested info event suppressed by default");

    my @on = run(Test2::Harness2::Collector::Assembler->new(emit_stray => 1), $info);
    is(scalar(@on), 1, "nested info event emitted with emit_stray");
    ok($on[0]->facet_data->{harness_auditor}{stray}, "the standalone copy is marked stray");
};

subtest streamed_tap_subtest_assembled => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # TAP subtest streamed: open at depth 0, two children at depth 1, close.
    my @out = run(
        $as,
        tap_open('st', 0),
        tap_assert(1, number => 1, name => 'child a', nested => 1),
        tap_assert(1, number => 2, name => 'child b', nested => 1),
        tap_close(0),
    );

    my $asm = assembled(@out);
    ok($asm, "an assembled subtest event was emitted");
    is($asm->facet_data->{parent}{details}, 'st', "assembled subtest named");
    is(scalar(@{$asm->facet_data->{parent}{children}}), 2, "both streamed children nested inside");
    is($asm->facet_data->{parent}{children}[0]{assert}{details}, 'child a', "first child captured");
};

subtest emit_stray_off_by_default => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;
    my @out = run(
        $as,
        tap_open('st', 0),
        tap_assert(1, number => 1, name => 'child a', nested => 1),
        tap_close(0),
    );

    my @stray = grep { $_->facet_data->{harness_auditor} && $_->facet_data->{harness_auditor}{stray} } @out;
    is(scalar(@stray), 0, "no stray events emitted by default");

    my @announce = grep { $_->facet_data->{harness}{subtest_started} } @out;
    is(scalar(@announce), 0, "no subtest-start announcement by default");

    ok(assembled(@out), "authoritative assembled event still emitted");
};

subtest emit_stray_on => sub {
    my $as = Test2::Harness2::Collector::Assembler->new(emit_stray => 1);
    my @out = run(
        $as,
        tap_open('st', 0),
        tap_assert(1, number => 1, name => 'child a', nested => 1),
        tap_close(0),
    );

    my @announce = grep { $_->facet_data->{harness}{subtest_started} } @out;
    is(scalar(@announce), 1, "subtest-start announcement emitted with emit_stray");
    ok($announce[0]->facet_data->{harness_auditor}{stray}, "announcement marked stray");

    my @child_copies = grep {
        $_->facet_data->{assert}
            && ($_->facet_data->{assert}{details} // '') eq 'child a'
            && $_->facet_data->{harness_auditor}
            && $_->facet_data->{harness_auditor}{stray}
    } @out;
    is(scalar(@child_copies), 1, "the streamed child appears standalone, marked stray");

    my $asm = assembled(@out);
    ok($asm, "assembled event still emitted");
    ok(!($asm->facet_data->{harness_auditor} && $asm->facet_data->{harness_auditor}{stray}), "assembled event NOT marked stray");
};

subtest nested_two_deep_assembled => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # outer { inner { grandchild } } streamed via TAP; closed by a depth-0 plan.
    my @out = run(
        $as,
        tap_open('outer', 0),
        tap_open('inner', 1),
        tap_assert(1, number => 1, name => 'grandchild', nested => 2),
        tap_close(1),
        tap_close(0),
        tap_plan(1),
    );

    my $asm = assembled(@out);
    ok($asm, "nested subtests assembled to one top-level event");
    is($asm->facet_data->{parent}{details}, 'outer', "top is the outer subtest");
    my ($inner) = grep { $_->{parent} && $_->{parent}{details} } @{$asm->facet_data->{parent}{children}};
    ok($inner, "inner subtest nested inside outer");
    is($inner->{parent}{details}, 'inner', "inner named");
    my ($gc) = grep { $_->{assert} && ($_->{assert}{details} // '') eq 'grandchild' } @{$inner->{parent}{children}};
    ok($gc, "grandchild nested inside inner");
};

done_testing;
