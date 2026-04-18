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
use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = tempdir(CLEANUP => 1);

# Trivial preload with one stage. No DSL body work -- the stage just needs
# to exist so its service loop can accept the launch_test message.
my $pkg_dir = File::Spec->catdir($dir, 'LaunchPre');
make_path($pkg_dir);
open my $fh, '>', File::Spec->catfile($pkg_dir, 'Simple.pm') or die $!;
print $fh <<'EOPM';
package LaunchPre::Simple;
use Test2::Harness2::Preload;
stage Default => sub {
    preload 'Carp';
};
1;
EOPM
close $fh;

# Simple test file that emits one passing assertion.
my $test_file = File::Spec->catfile($dir, 'ok.t');
open my $tfh, '>', $test_file or die $!;
print $tfh <<'EOT';
use Test2::V0;
ok(1, 'preloaded test ran');
done_testing;
EOT
close $tfh;

my $log_file = File::Spec->catfile($dir, 'events.jsonl');

my $bus = ipcm_spawn();

my $config = {
    workdir     => $dir,
    name        => 'preloader',
    ipcm_info   => $bus->info,
    parent_pids => [$$],
    preload     => ['LaunchPre::Simple'],
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

sub wait_ready {
    my ($handle, $deadline) = @_;
    while (time < $deadline) {
        return 1 if $handle->ready;
        sleep 0.05;
    }
    return 0;
}

my $preloader_handle = IPC::Manager::Service::Handle->new(
    service_name => 'preloader',
    ipcm_info    => $bus->info,
);

ok(wait_ready($preloader_handle, time + 20), "preloader ready")
    or do { kill 'TERM', $pid; waitpid $pid, 0; die "preloader never ready" };

my $stage_handle = IPC::Manager::Service::Handle->new(
    service_name => 'Default',
    ipcm_info    => $bus->info,
);
ok(wait_ready($stage_handle, time + 20), "stage 'Default' ready");

# Fire the launch. loggers is a single JSONL file so we can inspect its
# output to verify the test actually ran.
my $resp = $stage_handle->sync_request(
    'Default',
    {
        request   => 'launch_test',
        test_file => $test_file,
        loggers   => [
            [
                'Test2::Harness2::Collector::Logger::JSONL',
                output_file => $log_file,
            ],
        ],
        auditor  => 'Test2::Harness2::Collector::Auditor::Test',
    },
);

ok($resp->{response}->{ok}, "launch_test accepted") or diag explain $resp;
my $collector_pid = $resp->{response}->{collector_pid};
ok($collector_pid, "got collector pid");

# Wait for the collector to finish; it reaps its own child test and exits.
my $deadline = time + 30;
while (time < $deadline) {
    last unless kill 0, $collector_pid;
    sleep 0.1;
}
ok(!kill(0, $collector_pid), "collector exited");

# Check the log file got events. We expect at least one assertion event.
ok(-s $log_file, "log file has content");

my $seen_assert = 0;
my $seen_plan   = 0;
my @all_events;
open my $lfh, '<', $log_file or die $!;
while (my $line = <$lfh>) {
    chomp $line;
    next unless length $line;
    my $event = decode_json($line);
    push @all_events => $event;
    my $fd = $event->{facet_data};
    $seen_assert++ if $fd && $fd->{assert};
    $seen_plan++   if $fd && $fd->{plan};
}
close $lfh;

ok($seen_assert, "at least one assertion event in log")
    or diag "log events: " . do {
        require Data::Dumper;
        no warnings 'once';
        local $Data::Dumper::Indent = 1;
        Data::Dumper->Dump([\@all_events], ['events']);
    };

# Shut the preloader down cleanly.
$preloader_handle->sync_request('preloader', {request => 'shutdown'});

my $shutdown_deadline = time + 15;
while (kill 0, $pid) {
    last if waitpid($pid, POSIX::WNOHANG()) == $pid;
    if (time > $shutdown_deadline) {
        kill 'KILL' => $pid;
        waitpid $pid, 0;
        die "preloader did not exit in 15s";
    }
    sleep 0.05;
}

ok(!kill(0, $pid), "preloader exited");

done_testing;
