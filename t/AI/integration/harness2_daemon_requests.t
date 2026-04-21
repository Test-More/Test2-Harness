use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use App::Yath2::TestFile;

use Test2::Harness2;

# Exercises the new Stage 14 IPC request handlers on the harness
# service: ping, get_workdir, list_processes, list_resources,
# abort_runs, reload_preloads. Each is a round-trip via Spawn.

my $dir = tempdir(CLEANUP => 1);

my $spawn = Test2::Harness2->spawn(workdir => $dir);
isa_ok($spawn, ['Test2::Harness2::Spawn']);

subtest ping => sub {
    my $pong = $spawn->ping;
    ok($pong->{ok},            'ping ok');
    ok(defined $pong->{pong} && $pong->{pong} > 0, 'pong carries a pid');
    ok(defined $pong->{stamp}, 'pong carries a stamp');
};

subtest get_workdir => sub {
    my $res = $spawn->get_workdir;
    ok($res->{ok},            'get_workdir ok');
    is($res->{workdir}, $dir, 'workdir matches');
    ok(defined $res->{logdir}, 'logdir reported');
    is($res->{name}, 'harness', 'default harness name');
};

subtest list_processes_pre_run => sub {
    my $res = $spawn->list_processes;
    ok($res->{ok}, 'list_processes ok');
    my @harness = grep { $_->{role} eq 'harness' } @{$res->{processes}};
    is(scalar(@harness), 1, 'exactly one harness entry');
    ok($harness[0]->{pid} > 0, 'harness pid present');
    is($harness[0]->{name}, 'harness', 'harness name');
};

subtest list_resources_default => sub {
    my $res = $spawn->list_resources;
    ok($res->{ok}, 'list_resources ok');
    my ($jc) = grep { $_->{resource_name} eq 'jobcount' } @{$res->{resources}};
    ok($jc, 'jobcount resource present');
    is($jc->{scope}, 'global', 'jobcount is global');
};

subtest abort_runs_noop_when_empty => sub {
    my $res = $spawn->abort_runs;
    ok($res->{ok}, 'abort_runs ok with nothing queued');
    is($res->{aborted}, [], 'nothing aborted');
};

subtest reload_preloads_none => sub {
    my $res = $spawn->reload_preloads;
    ok($res->{ok}, 'reload_preloads ok with no preload resource');
    is($res->{reloaded}, [], 'no preloads to reload');
};

$spawn->finish;
$spawn->wait;

done_testing;
