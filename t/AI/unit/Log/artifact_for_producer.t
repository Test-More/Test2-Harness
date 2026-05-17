use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use App::Yath2::Log;
use App::Yath2::Log::Producer::Job;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/runs/1/jobs/1/0");
open my $fh, '>', "$dir/runs/1/jobs/1/0/spec.jsonl" or die "open: $!";
print $fh qq[{"job_id":"1"}\n];
close $fh;

my $log = App::Yath2::Log->new(dir => $dir);

# Build a descriptor by hand to isolate this method's behavior
# (the iterator that builds these comes in Task 1A.8).
my $p = App::Yath2::Log::Producer::Job->new(
    id            => '1',
    parent_id     => '1',
    run_id        => '1',
    try           => 0,
    state         => 'partial',
    log           => $log,
    artifact_refs => {spec => 'runs/1/jobs/1/0/spec.jsonl'},
);

# Test artifact_for_producer directly on the log
my $r = $log->artifact_for_producer($p, 'spec');
ok($r, 'spec reader returned from artifact_for_producer');
isa_ok($r, ['Test2::Harness2::Util::JSONL::Reader'], 'reader is a JSONL::Reader');

my $first_line = $r->readline;
ok(defined $first_line, 'got a line from the reader');
like($first_line, {job_id => '1'}, 'reads spec content (decoded JSON hashref)');

# Test via producer's artifact() shortcut (delegates to the log)
my $r2 = $p->artifact('spec');
ok($r2, 'spec reader returned via producer->artifact()');
my $line2 = $r2->readline;
ok(defined $line2, 'got a line via producer->artifact()');
like($line2, {job_id => '1'}, 'producer->artifact() reads correct content');

# Missing artifact kind returns undef without erroring.
ok(
    !defined $log->artifact_for_producer($p, 'nonexistent'),
    'unknown kind returns undef'
);
ok(
    !defined $p->artifact('nonexistent'),
    'producer->artifact() also returns undef for unknown kind'
);

# No-log producer returns undef from artifact() without crashing.
my $p_nolog = App::Yath2::Log::Producer::Job->new(
    id    => '2',
    state => 'partial',
    try   => 0,
);
ok(!defined $p_nolog->artifact('spec'), 'no-log producer->artifact() returns undef');

done_testing;
