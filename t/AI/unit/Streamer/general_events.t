use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic encode_json/;

use App::Yath2::Streamer::Static;

# Build a synthetic log dir that carries a records_state JSON snapshot
# plus a records_general_events JSONL with two pre-recorded event
# hashes. Verify the streamer pulls both the synthesized lifecycle
# events (from the state) and the pass-through events (from the JSONL).

my $tmp    = tempdir(CLEANUP => 1);
my $logdir = "$tmp/logs";
make_path("$logdir/runs/R/tests/J");

# Phase 4: every runs/<id>/ must carry spec.json. The static streamer
# reads every *.json under runs/<id>/ as a state snapshot (loggers are
# resolved by extension), so spec.json and state.json must agree --
# mirror the same content into both.
my $state = {
    run_id  => 'R', created_at => 1, pending => [], running => [],
    done    => ['J'],
    results => {
        J => {
            queued_at => 1, started_at => 2, completed_at => 3,
            pass => 1, exit => 0,
            rel_file => 't/j.t', abs_file => '/abs/t/j.t', file => '/abs/t/j.t',
        },
    },
};
write_json_file_atomic("$logdir/runs/R/spec.json",  $state);
write_json_file_atomic("$logdir/runs/R/state.json", $state);

# Write two raw events to the JSONL. Their payloads are opaque to the
# streamer but they must come through untouched so the renderer sees
# them in order.
open my $jf, '>', "$logdir/runs/R/tests/J/0.jsonl" or die $!;
$jf->autoflush(1);
print $jf encode_json({event_id => 'EV1', facet_data => {info => [{details => 'pre'}]}}), "\n";
print $jf encode_json({event_id => 'EV2', facet_data => {info => [{details => 'post'}]}}), "\n";
close $jf;

my $streamer = App::Yath2::Streamer::Static->new(log => $logdir, run => 'R');

my (@synth, @general);
while (my $event = $streamer->next) {
    my $fd = $event->facet_data // {};
    if ($fd->{harness_run} || $fd->{harness_run_end}
        || $fd->{harness_job_queued} || $fd->{harness_job_start}
        || $fd->{harness_job_end})
    {
        push @synth => $event;
    }
    else {
        push @general => $event;
    }
}

ok(scalar(@synth) >= 3,   'synthesised lifecycle events present (got ' . scalar(@synth) . ')');
is(scalar(@general), 2,   'both pre-recorded general events streamed');

is([map { $_->{event_id} } @general], ['EV1', 'EV2'], 'general events pass through in order');

done_testing;
