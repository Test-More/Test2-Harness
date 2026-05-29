use Test2::V0;
use v5.38;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor::TimeTracker;

# The time tracker accumulates timing from an event stream and reports the
# startup / events / cleanup / total phase durations. Stamps come from facets
# (trace.stamp for test events; the process-exit facet carries the launch and
# reap stamps), since events have no top-level stamp in this architecture.

sub ev ($fd) { return Test2::Harness2::Event->new(facet_data => $fd) }
sub trace_ev ($stamp) { return ev({trace => {stamp => $stamp}, assert => {pass => 1}}) }
sub exit_ev ($start, $stop) { return ev({harness_process_exit => {start_stamp => $start, stamp => $stop, all => 0}}) }

subtest phase_durations => sub {
    my $tt = Test2::Harness2::Collector::Auditor::TimeTracker->new;

    $tt->process(trace_ev(10));
    $tt->process(trace_ev(12));
    $tt->process(exit_ev(8, 15));

    ok($tt->useful, "tracker has useful data");

    my $t = $tt->totals;
    is($t->{startup}, 2, "startup = first - start (10 - 8)");
    is($t->{events},  2, "events  = last - first (12 - 10)");
    is($t->{cleanup}, 3, "cleanup = stop - last (15 - 12)");
    is($t->{total},   7, "total   = stop - start (15 - 8)");
};

subtest plan_ends_event_phase => sub {
    my $tt = Test2::Harness2::Collector::Auditor::TimeTracker->new;

    $tt->process(trace_ev(10), 0);
    $tt->process(trace_ev(12), 1);
    # The plan (with assertions already seen) closes the event phase; it still
    # counts as the last event, but later stray events must not extend it.
    $tt->process(ev({trace => {stamp => 14}, plan => {count => 1}}), 1);
    $tt->process(trace_ev(99), 1);
    $tt->process(exit_ev(8, 20));

    my $t = $tt->totals;
    is($t->{events}, 4, "event phase ends at the plan (14 - 10), ignoring the stray late event");
};

subtest not_useful_when_empty => sub {
    my $tt = Test2::Harness2::Collector::Auditor::TimeTracker->new;
    ok(!$tt->useful, "no data -> not useful");
};

done_testing;
