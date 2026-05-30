use Test2::V0;
use v5.38;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Assembler;

# The assembler coalesces scattered subtest events into one nested authoritative
# event per top-level subtest. Subtests arrive three ways: buffered Stream2
# (already nested -> passed through), buffered TAP (ok...{ / } with depth), and
# unbuffered/streamed (depth-stamped events, closed by a shallower event). The
# assembler correlates purely by nesting depth + arrival order.

sub ev ($fd) { return Test2::Harness2::Event->new(facet_data => $fd) }

sub assert_f ($pass, %e) {
    my %f = (assert => {pass => $pass ? 1 : 0, details => $e{name} // 'an assertion'});
    $f{assert}{number} = $e{number} if exists $e{number};
    $f{trace}          = {nested => $e{nested}} if $e{nested};
    return \%f;
}

sub run ($assembler, @facets) {
    return map { $assembler->process_event(ev($_)) } @facets;
}

# Pull the one assembled top-level subtest event (the one carrying
# parent.children) out of an output list.
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
    my $as = Test2::Harness2::Collector::Assembler->new;
    my @out = run($as, {assert => {pass => 1, details => 'a plain assert'}, trace => {nested => 0}});
    is(scalar(@out), 1, "a plain top-level event passes straight through");
    is($out[0]->facet_data->{assert}{details}, 'a plain assert', "unchanged");
};

subtest buffered_stream2_passthrough => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # A buffered Stream2 subtest arrives already nested; hub marks it buffered.
    my $sub = {
        assert => {pass => 1, details => 'buffered st', number => 1},
        parent => {details => 'buffered st', children => [assert_f(1, number => 1)]},
        hubs   => [{nested => 0, buffered => 1}],
    };

    my @out = run($as, $sub);
    is(scalar(@out), 1, "already-buffered subtest passes straight through");
    ok($out[0]->facet_data->{parent}{children}, "children preserved");
};

subtest streamed_subtest_assembled => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # subtest_start at depth 0, two children at depth 1, then a shallower event
    # (the plan at depth 0) closes the subtest.
    my @out = run(
        $as,
        {harness => {subtest_start => 1}, parent => {details => 'st'}, assert => {pass => 1, details => 'st', number => 1}, trace => {nested => 0}},
        assert_f(1, number => 1, name => 'child a', nested => 1),
        assert_f(1, number => 2, name => 'child b', nested => 1),
        {plan => {count => 1}, trace => {nested => 0}},
    );

    my $asm = assembled(@out);
    ok($asm, "an assembled subtest event was emitted");
    is($asm->facet_data->{parent}{details}, 'st', "assembled subtest named");
    is(scalar(@{$asm->facet_data->{parent}{children}}), 2, "both streamed children nested inside");
    is($asm->facet_data->{parent}{children}[0]{assert}{details}, 'child a', "first child captured");
};

subtest buffered_tap_assembled => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # TAP buffered subtest: ok ... { open, child at depth 1, } close.
    my @out = run(
        $as,
        {from_tap => {source => 'STDOUT', details => 'ok 1 - st {'}, harness => {subtest_start => 1}, parent => {details => 'st'}, assert => {pass => 1, details => 'st', number => 1}, trace => {nested => 0}},
        {from_tap => {source => 'STDOUT', details => 'ok 1 - child'}, assert => {pass => 1, details => 'child', number => 1}, trace => {nested => 1}},
        {from_tap => {source => 'STDOUT', details => '}'}, harness => {subtest_end => 1}, parent => {}, trace => {nested => 0}},
    );

    my $asm = assembled(@out);
    ok($asm, "a TAP subtest was assembled");
    is($asm->facet_data->{parent}{details}, 'st', "TAP subtest named");
    is(scalar(@{$asm->facet_data->{parent}{children}}), 1, "one child nested");
};

subtest emit_stray_off_by_default => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;
    my @out = run(
        $as,
        {harness => {subtest_start => 1}, parent => {details => 'st'}, assert => {pass => 1, details => 'st', number => 1}, trace => {nested => 0}},
        assert_f(1, number => 1, name => 'child a', nested => 1),
        {plan => {count => 1}, trace => {nested => 0}},
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
        {harness => {subtest_start => 1}, parent => {details => 'st'}, assert => {pass => 1, details => 'st', number => 1}, trace => {nested => 0}},
        assert_f(1, number => 1, name => 'child a', nested => 1),
        {plan => {count => 1}, trace => {nested => 0}},
    );

    my @announce = grep { $_->facet_data->{harness}{subtest_started} } @out;
    is(scalar(@announce), 1, "subtest-start announcement emitted with emit_stray");
    ok($announce[0]->facet_data->{harness_auditor}{stray}, "announcement marked stray");

    my @child_copies = grep { $_->facet_data->{assert} && ($_->facet_data->{assert}{details} // '') eq 'child a' } @out;
    is(scalar(@child_copies), 1, "the streamed child appears standalone");
    ok($child_copies[0]->facet_data->{harness_auditor}{stray}, "standalone child marked stray");

    my $asm = assembled(@out);
    ok($asm, "assembled event still emitted");
    ok(!$asm->facet_data->{harness_auditor}{stray}, "assembled event NOT marked stray");
};

subtest nested_two_deep_assembled => sub {
    my $as = Test2::Harness2::Collector::Assembler->new;

    # outer { inner { grandchild } } streamed; closed by a depth-0 plan.
    my @out = run(
        $as,
        {harness => {subtest_start => 1}, parent => {details => 'outer'}, assert => {pass => 1, details => 'outer', number => 1}, trace => {nested => 0}},
        {harness => {subtest_start => 1}, parent => {details => 'inner'}, assert => {pass => 1, details => 'inner', number => 1}, trace => {nested => 1}},
        assert_f(1, number => 1, name => 'grandchild', nested => 2),
        {plan => {count => 1}, trace => {nested => 0}},
    );

    my $asm = assembled(@out);
    ok($asm, "nested subtests assembled to one top-level event");
    is($asm->facet_data->{parent}{details}, 'outer', "top is the outer subtest");
    my $inner = $asm->facet_data->{parent}{children}[0];
    is($inner->{parent}{details}, 'inner', "inner nested inside outer");
    is($inner->{parent}{children}[0]{assert}{details}, 'grandchild', "grandchild nested inside inner");
};

done_testing;
