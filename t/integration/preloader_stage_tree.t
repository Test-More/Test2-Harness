use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Spec ();
use File::Path qw/make_path/;
use Time::HiRes qw/time sleep/;
use POSIX ();

use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle ();

use Test2::Harness2::Preloader;

my $dir = tempdir(CLEANUP => 1);

# Lay down a tiny preload library with two top-level stages and one nested.
my $pkg_dir = File::Spec->catdir($dir, 'MyPre');
make_path($pkg_dir);
open my $fh, '>', File::Spec->catfile($pkg_dir, 'Tree.pm') or die $!;
print $fh <<'EOPM';
package MyPre::Tree;
use Test2::Harness2::Preload;
stage Alpha => sub {
    preload 'Carp';
    stage AlphaInner => sub {
        preload 'Scalar::Util';
    };
};
stage Beta => sub {
    preload 'List::Util';
};
1;
EOPM
close $fh;

my $bus = ipcm_spawn();

my $config = {
    workdir     => $dir,
    name        => 'preloader',
    ipcm_info   => $bus->info,
    parent_pids => [$$],
    preload     => ['MyPre::Tree'],
};
my $cfg_file = Test2::Harness2::Preloader->write_config_file($dir, $config);

my @argv = (
    $^X,
    "-I$dir",
    (map { "-I$_" } grep { defined $_ && length $_ } @INC),
    '-e', Test2::Harness2::Preloader->bootstrap_script,
    '--', $cfg_file,
);

my $pid = fork // die "fork: $!";
unless ($pid) {
    exec { $argv[0] } @argv or do {
        warn "exec failed: $!\n";
        POSIX::_exit(127);
    };
}

my $preloader_handle = IPC::Manager::Service::Handle->new(
    service_name => 'preloader',
    ipcm_info    => $bus->info,
);

sub wait_ready {
    my ($handle, $deadline) = @_;
    while (time < $deadline) {
        return 1 if $handle->ready;
        sleep 0.05;
    }
    return 0;
}

ok(wait_ready($preloader_handle, time + 20), "preloader ready")
    or do { kill 'TERM', $pid; waitpid $pid, 0; die "preloader never ready" };

# Status should list all three stage names.
my $status_resp = $preloader_handle->sync_request('preloader', {request => 'status'});
my $s = $status_resp->{response};
ok($s->{ok}, "status ok");
is(
    [sort @{$s->{stages}}],
    [qw/Alpha AlphaInner Beta/],
    "all three stages in preloader status",
);

# Each top-level stage should be reachable by its service name via IPC.
for my $name (qw/Alpha Beta/) {
    my $h = IPC::Manager::Service::Handle->new(
        service_name => $name,
        ipcm_info    => $bus->info,
    );
    ok(wait_ready($h, time + 20), "top-level stage '$name' ready");
    my $r = $h->sync_request($name, {request => 'ping'});
    ok($r->{response}->{ok}, "ping $name ok");
    is($r->{response}->{stage}, $name, "stage name carried");
}

# The nested AlphaInner should also be up (spawned by Alpha during
# _spawn_child_stages).
my $ai = IPC::Manager::Service::Handle->new(
    service_name => 'AlphaInner',
    ipcm_info    => $bus->info,
);
ok(wait_ready($ai, time + 20), "nested AlphaInner ready");
my $ai_resp = $ai->sync_request('AlphaInner', {request => 'status'});
is(
    $ai_resp->{response}->{loaded},
    ['Scalar::Util'],
    "AlphaInner loaded Scalar::Util from its load sequence",
);

# Shut the preloader down cleanly.
$preloader_handle->sync_request('preloader', {request => 'shutdown'});

my $deadline = time + 15;
while (kill 0, $pid) {
    last if waitpid($pid, POSIX::WNOHANG()) == $pid;
    if (time > $deadline) {
        kill 'KILL' => $pid;
        waitpid $pid, 0;
        die "preloader did not exit in 15s";
    }
    sleep 0.05;
}

ok(!kill(0, $pid), "preloader process exited");

done_testing;
