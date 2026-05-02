use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use App::Yath2::LogArchive;
use App::Yath2::Streamer::Static;

my $tmp   = tempdir(CLEANUP => 1);
my $logs  = "$tmp/logs";
make_path("$logs/runs/RUN1/tests");

# Phase 4: every runs/<id>/ must carry spec.json. The static streamer
# reads every *.json under runs/<id>/ as a state snapshot (loggers are
# resolved by extension), so spec.json and state.json must agree --
# mirror the same content into both.
my $state = {
    run_id     => 'RUN1',
    created_at => 1000,
    pending    => [],
    running    => [],
    done       => ['A', 'B'],
    results    => {
        A => {
            queued_at    => 1000, started_at => 1001, completed_at => 1002,
            pass => 1, exit => 0,
            rel_file => 't/a.t', abs_file => '/abs/t/a.t', file => '/abs/t/a.t',
        },
        B => {
            queued_at    => 1000, started_at => 1003, completed_at => 1004,
            pass => 0, exit => 256,
            rel_file => 't/b.t', abs_file => '/abs/t/b.t', file => '/abs/t/b.t',
        },
    },
};
write_json_file_atomic("$logs/runs/RUN1/spec.json",  $state);
write_json_file_atomic("$logs/runs/RUN1/state.json", $state);

# Pack the logs directory as a .yath archive.
my $archive_path = "$tmp/run.yath";
App::Yath2::LogArchive->open(dir => $logs)->archive($archive_path);
ok(-f $archive_path, "archive written at $archive_path");

# Streamer opens the archive directly.
my $streamer = App::Yath2::Streamer::Static->new(
    log => $archive_path,
    run => 'RUN1',
);

my @events;
while (my $event = $streamer->next) {
    push @events => $event;
}

ok(scalar(@events) >= 5, "produced events from archive (got " . scalar(@events) . ')');

my %facets;
for my $e (@events) {
    my $fd = $e->facet_data // {};
    for my $k (keys %$fd) { push @{$facets{$k}} => $fd->{$k} }
}

ok($facets{harness_run_end},    'harness_run_end emitted');
ok($facets{harness_job_queued}, 'harness_job_queued emitted');
ok($facets{harness_job_start},  'harness_job_start emitted');
ok($facets{harness_job_end},    'harness_job_end emitted');

my @ended = sort map { $_->{job_id} } @{$facets{harness_job_end} // []};
is(\@ended, [sort qw/A B/], 'both jobs reported as ended');

my $run_end = $facets{harness_run_end}->[0];
is($run_end->{pass},       0, 'run_end pass=0 (B failed)');
is($run_end->{pass_count}, 1, 'run_end pass_count=1');
is($run_end->{fail_count}, 1, 'run_end fail_count=1');

# Lazy extraction: only the state artifact should have been pulled
# out of the archive. The archive also contains a harness JSONL the
# streamer does not need, so that file must NOT have been extracted.
my $extracted = $streamer->{archive_extracted} // {};
ok(
    (grep { m{^runs/RUN1/state\.json\z} } keys %$extracted),
    'state artifact was extracted on demand',
);
ok(
    !(grep { m{harness\.(jsonl|json)\z} } keys %$extracted),
    'unrelated harness logs were NOT extracted',
);

done_testing;
