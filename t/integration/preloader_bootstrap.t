use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/time sleep/;
use POSIX ();

use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle ();

use Test2::Harness2::Preloader;

my $dir = tempdir(CLEANUP => 1);

# Stand up the IPC bus.
my $bus = ipcm_spawn();
isa_ok($bus, ['IPC::Manager::Spawn']);

# Build a config that asks for a single plain preload.
my $config = {
    workdir     => $dir,
    name        => 'preloader',
    ipcm_info   => $bus->info,
    parent_pids => [$$],
    preload     => ['Carp'],
};
my $cfg_file = Test2::Harness2::Preloader->write_config_file($dir, $config);

# Fork+exec the bootstrap script.
my @argv = Test2::Harness2::Preloader->build_exec_argv(config_file => $cfg_file);

my $pid = fork // die "fork: $!";
unless ($pid) {
    exec { $argv[0] } @argv or do {
        warn "exec failed: $!\n";
        POSIX::_exit(127);
    };
}

# Connect a client handle and wait for the service to be ready.
my $handle = IPC::Manager::Service::Handle->new(
    service_name => 'preloader',
    ipcm_info    => $bus->info,
);

my $ready_deadline = time + 15;
until ($handle->ready) {
    if (time > $ready_deadline) {
        kill 'TERM' => $pid;
        waitpid $pid, 0;
        die "preloader did not become ready within 15s";
    }
    sleep 0.05;
}

# Ping.
my $resp = $handle->sync_request('preloader', {request => 'ping'});
my $r = $resp->{response};
ok($r->{ok},             "ping ok=1");
is($r->{pong}, $pid,     "pong carries preloader pid");
is($r->{name}, 'preloader', "name carried through");

# Status should reflect the preload list.
my $stat_resp = $handle->sync_request('preloader', {request => 'status'});
my $s = $stat_resp->{response};
ok($s->{ok},                       "status ok");
is($s->{preloads}, ['Carp'],       "preloads round-trip");
is($s->{stages},   [],             "no stages without DSL preload");
like($s->{jump_label}, qr/^preloader_root_/, "jump label looks right");

# Shut the preloader down cleanly.
my $sd = $handle->sync_request('preloader', {request => 'shutdown'});
ok($sd->{response}->{ok}, "shutdown accepted");

my $deadline = time + 10;
while (kill 0, $pid) {
    last if waitpid($pid, POSIX::WNOHANG()) == $pid;
    if (time > $deadline) {
        kill 'KILL' => $pid;
        waitpid $pid, 0;
        die "preloader did not exit in 10s";
    }
    sleep 0.05;
}

ok(!kill(0, $pid), "preloader process exited");

done_testing;
