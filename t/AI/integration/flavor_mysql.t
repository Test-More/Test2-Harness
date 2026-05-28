use Test2::V0;
use Test2::Harness2;
use Test2::Util::UUID qw/gen_uuid/;

BEGIN {
    eval { require DBIx::QuickDB; 1 } or skip_all "DBIx::QuickDB not available";
    eval { require DBD::mysql;    1 } or skip_all "DBD::mysql not available";
    require DBIx::QuickDB::Driver::MySQL;
    # viable() takes a single hashref; the 2-arg form crashes the driver.
    my ($ok, $why) = DBIx::QuickDB::Driver::MySQL->viable({bootstrap => 1, autostart => 1});
    skip_all "MySQL not provisionable: $why" unless $ok;
}

my $h = Test2::Harness2->new(ephemeral => 'mysql');
$h->initialize;

my $con = $h->connection;
ok($con, 'connected to ephemeral mysql');

# project + run round-trip: exercises uuid, datetime, boolean paths.
my $proj = $con->handle('project')->insert({name => 'proj-mysql'});
ok($proj->field('project_id'), 'project insert returns id');

my $runner_uuid = gen_uuid();
$con->handle('runner')->insert({runner_uuid => $runner_uuid});

my $run = $h->queue_run(
    runner_uuid => $runner_uuid,
    project_id  => $proj->field('project_id'),
    files       => ['t/foo.t', 't/bar.t'],
);
ok($run->field('run_uuid'), 'run inserted');

$run->refresh;
isa_ok($run->field('started'), ['DateTime'], 'started inflated to DateTime');
my @jobs = $con->handle('job', where => {run_uuid => $run->field('run_uuid')})->all;
is(scalar(@jobs), 2, 'two jobs queued');

like($run->field('run_uuid'), qr/^[0-9a-f]{8}-[0-9a-f]{4}-/i, 'uuid is canonical string');
is($run->field('passed'), undef, 'passed is NULL/undecided');

done_testing;
