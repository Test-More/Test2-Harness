use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use App::Yath2::Streamer::Static;

my $tmp = tempdir(CLEANUP => 1);
my $logdir = "$tmp/logs";
make_path("$logdir/runs/RUN1/tests");

# Phase 4: every runs/<id>/ must carry spec.json. The static streamer
# picks up *.json under runs/<id>/ by extension, so spec.json and
# state.json must agree -- mirror the same snapshot into both.
my $state = {
    run_id     => 'RUN1',
    created_at => 100,
    pending    => [],
    running    => [],
    done       => ['J1'],
    results    => {
        J1 => {
            queued_at    => 100,
            started_at   => 101,
            completed_at => 102,
            pass         => 1,
            exit         => 0,
            codes        => {all => 0, sig => 0, dmp => 0, err => 0},
            rel_file     => 't/j1.t',
            abs_file     => '/abs/t/j1.t',
            file         => '/abs/t/j1.t',
        },
        J_SKIPPED => {
            queued_at => 100,
            rel_file  => 't/skip.t',
            abs_file  => '/abs/t/skip.t',
            file      => '/abs/t/skip.t',
            # No started_at / completed_at: this job was queued
            # but never ran.
        },
    },
};
write_json_file_atomic("$logdir/runs/RUN1/spec.json",  $state);
write_json_file_atomic("$logdir/runs/RUN1/state.json", $state);

my $streamer = App::Yath2::Streamer::Static->new(
    log => $logdir,
    run => 'RUN1',
);

my @events;
while (my $event = $streamer->next) {
    push @events => $event;
}

ok(scalar(@events) >= 3, "produced multiple lifecycle events (got " . scalar(@events) . ')');

my %facets;
for my $e (@events) {
    my $fd = $e->facet_data // {};
    for my $k (keys %$fd) {
        push @{$facets{$k}} => $fd->{$k};
    }
}

ok($facets{harness_run},         'emitted at least one harness_run facet');
ok($facets{harness_run_end},     'emitted a harness_run_end facet');
ok($facets{harness_job_queued},  'emitted harness_job_queued');
ok($facets{harness_job_start},   'emitted harness_job_start');
ok($facets{harness_job_end},     'emitted harness_job_end');

# The skipped-but-queued job should have a queued event but no
# start/end; the completed job should have all three.
my @queued = map { $_->{job_id} } @{$facets{harness_job_queued} // []};
is([sort @queued], [sort qw/J1 J_SKIPPED/], 'both jobs seen as queued');

my @started = map { $_->{job_id} } @{$facets{harness_job_start} // []};
is([sort @started], ['J1'], 'only J1 reported as started');

my @ended = map { $_->{job_id} } @{$facets{harness_job_end} // []};
is([sort @ended], ['J1'], 'only J1 reported as ended');

# Run end aggregate: one passing job, no failures.
my $run_end = $facets{harness_run_end}->[0];
is($run_end->{pass},       1, 'run_end pass=1');
is($run_end->{pass_count}, 1, 'run_end pass_count=1');
is($run_end->{fail_count}, 0, 'run_end fail_count=0');

done_testing;
