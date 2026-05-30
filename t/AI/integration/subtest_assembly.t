use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# End-to-end: a real Test2::V0 job with nested subtests, run through the full
# parser -> assembler -> auditor -> recorder pipeline. Confirms the assembler
# coalesces the streamed Stream2 subtest events into one authoritative nested
# event per top-level subtest, and that the recorded log is free of the
# redundant standalone child copies unless emit_stray is requested.

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @events;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

sub run_job (%opts) {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    my $assembler = $opts{stray}
        ? ['Test2::Harness2::Collector::Assembler', emit_stray => 1]
        : 'Test2::Harness2::Collector::Assembler';

    Test2::Harness2::Collector->start(
        name         => "subtest-assembly", is_test => 1, run_uuid => "RUN",
        processor    => [$assembler, 'Test2::Harness2::Collector::Auditor'],
        recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-Ilib', 't/AI/scripts/subtest_job.pl'],
    );

    return [read_events($ef)];
}

# subtest_job.pl: top-level "ok", then outer { child a; child b; inner { grandchild } }.
my $details = sub ($e) { $e->{facet_data}{assert} ? ($e->{facet_data}{assert}{details} // '') : '' };
my $nested  = sub ($e) {
    my $fd = $e->{facet_data};
    return $fd->{hubs} ? $fd->{hubs}[0]{nested} : ($fd->{trace} ? $fd->{trace}{nested} : undef);
};
my $is_stray = sub ($e) { $e->{facet_data}{harness_auditor} && $e->{facet_data}{harness_auditor}{stray} };

subtest default_authoritative_only => sub {
    my $events = run_job();

    # Exactly one authoritative top-level subtest event, carrying the full tree.
    my ($outer) = grep { ($details->($_) eq 'outer') && !$is_stray->($_) } @$events;
    ok($outer, "outer subtest recorded as one authoritative event");
    is(scalar(@{$outer->{facet_data}{parent}{children}}), 4, "outer holds its 4 children (child a, child b, inner, plan)");

    # The inner subtest is nested INSIDE outer, not standalone.
    my ($inner_child) = grep { $_->{facet_data}{parent} && ($_->{facet_data}{assert}{details} // '') eq 'inner' }
        @{$outer->{facet_data}{parent}{children}};
    ok($inner_child, "inner subtest is nested inside outer's children");
    ok($inner_child->{parent}{children}, "inner carries its own nested children (grandchild + plan)");

    # No standalone child/grandchild events leak into the log.
    my @leaked = grep { ($details->($_) =~ /^(child a|child b|grandchild)$/) } @$events;
    is(scalar(@leaked), 0, "no standalone subtest-child events in a default log");

    # Nothing is marked stray by default.
    my @stray = grep { $is_stray->($_) } @$events;
    is(scalar(@stray), 0, "no stray-marked events by default");

    # The top-level non-subtest assertion is still present and authoritative.
    ok((grep { $details->($_) eq 'top level pass' } @$events), "top-level assertion recorded");
};

subtest emit_stray_adds_realtime_copies => sub {
    my $events = run_job(stray => 1);

    # The authoritative outer event is still present and NOT stray.
    my ($outer) = grep { ($details->($_) eq 'outer') && !$is_stray->($_) } @$events;
    ok($outer, "authoritative outer event still present with emit_stray");
    is(scalar(@{$outer->{facet_data}{parent}{children}}), 4, "outer still holds its 4 children");

    # The streamed children now appear standalone, each marked stray.
    for my $name (qw/child_a child_b grandchild/) {
        (my $want = $name) =~ s/_/ /;
        my @copies = grep { $details->($_) eq $want } @$events;
        ok(scalar(@copies) >= 1, "streamed '$want' appears standalone with emit_stray");
        ok((!grep { !$is_stray->($_) } @copies), "every standalone '$want' copy is marked stray");
    }
};

subtest info_inside_subtest_survives => sub {
    # note()/diag() inside a subtest are NOT folded into Test2's parent.children,
    # so the assembler must NOT suppress them -- otherwise they vanish from the
    # log entirely (neither standalone nor nested).
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    Test2::Harness2::Collector->start(
        name         => "subtest-info", is_test => 1, run_uuid => "RUN",
        processor    => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-Ilib', 't/AI/scripts/subtest_diag_job.pl'],
    );

    my @events = read_events($ef);

    my $info_seen = sub ($re) {
        return scalar grep {
            my $info = $_->{facet_data}{info} or return 0;
            grep { ($_->{details} // '') =~ $re } @$info;
        } @events;
    };

    ok($info_seen->(qr/NOTE inside the subtest/), "note() inside a subtest survives to the log");
    ok($info_seen->(qr/DIAG inside the subtest/), "diag() inside a subtest survives to the log");

    # Structural children are still de-duplicated (no standalone copies).
    my @dupes = grep {
        $_->{facet_data}{assert}
            && ($_->{facet_data}{assert}{details} // '') =~ /^child [ab]$/
            && !($_->{facet_data}{harness_auditor} && $_->{facet_data}{harness_auditor}{stray})
    } @events;
    is(scalar(@dupes), 0, "structural subtest children still de-duplicated");
};

subtest verdict_still_correct => sub {
    # The assembler must not disturb the auditor's verdict: an all-pass nested
    # job exits 0.
    my $dir = tempdir(CLEANUP => 1);
    my $exit = Test2::Harness2::Collector->start(
        name         => "subtest-verdict", is_test => 1, run_uuid => "RUN",
        processor    => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder     => Test2::Harness2::Collector::Recorder->new(events_file => "$dir/e.jsonl.zst"),
        exec_command => [$^X, '-Ilib', 't/AI/scripts/subtest_job.pl'],
    );
    is($exit, 0, "all-pass nested-subtest job audits to a passing exit");
};

done_testing;
