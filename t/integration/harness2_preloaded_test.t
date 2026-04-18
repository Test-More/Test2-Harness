use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Spec ();
use File::Path qw/make_path/;
use Time::HiRes qw/time sleep/;
use POSIX ();

use Test2::Harness2;
use Test2::Harness2::Util::JSON qw/decode_json/;

my $dir = tempdir(CLEANUP => 1);

# Tiny preload library with a single Default stage.
my $pre_dir = File::Spec->catdir($dir, 'HarnPre');
make_path($pre_dir);
open my $fh, '>', File::Spec->catfile($pre_dir, 'Simple.pm') or die $!;
print $fh <<'EOPM';
package HarnPre::Simple;
use Test2::Harness2::Preload;
stage Default => sub {
    preload 'Carp';
};
1;
EOPM
close $fh;

# The preloader forks itself via `perl -I<entries> -e`. Without the preload
# library's dir on @INC, the exec'd preloader cannot find the preload
# module. Seed PERL5LIB so the bootstrap script inherits the right @INC.
local $ENV{PERL5LIB} = join(':', $dir, ($ENV{PERL5LIB} // ''));

# Trivial test file.
my $test_file = File::Spec->catfile($dir, 'ok.t');
open my $tfh, '>', $test_file or die $!;
print $tfh <<'EOT';
use Test2::V0;
ok(1, 'preloaded test under harness ran');
done_testing;
EOT
close $tfh;

# Start the harness with the preload configured.
my $spawn = Test2::Harness2->spawn(
    workdir => $dir,
    preload => ['HarnPre::Simple'],
);
isa_ok($spawn, ['Test2::Harness2::Spawn']);

# The preloader spawn is async: wait until the stage service registers.
my $stage_ready = 0;
my $deadline    = time + 30;
while (time < $deadline) {
    my $s = $spawn->status;
    if (defined $s->{service}) {
        require IPC::Manager::Service::Handle;
        my $h = IPC::Manager::Service::Handle->new(
            service_name => 'Default',
            ipcm_info    => $spawn->ipcm_info,
        );
        if ($h->ready) { $stage_ready = 1; last }
    }
    sleep 0.1;
}
ok($stage_ready, "stage service 'Default' became ready")
    or do { $spawn->terminate; die "stage never ready" };

# Fire a launch_test_in_preload request through the harness.
my $resp = $spawn->launch_test_in_preload(
    stage     => 'Default',
    test_file => $test_file,
);
ok($resp->{ok}, "harness accepted launch_test_in_preload") or diag explain $resp;
ok($resp->{collector_pid}, "response carries collector_pid");
ok($resp->{run_id},        "response carries run_id");
ok($resp->{job_id},        "response carries job_id");

# Wait for the collector to finish.
my $cpid = $resp->{collector_pid};
my $col_deadline = time + 30;
while (time < $col_deadline) {
    last unless kill 0, $cpid;
    sleep 0.1;
}

# The harness assigned run_id/job_id - the logger wrote to the default
# location under $workdir/runs/$run_id/$job_id/0.jsonl.
my $log = File::Spec->catfile(
    $dir, 'runs', $resp->{run_id}, $resp->{job_id}, '0.jsonl',
);
ok(-s $log, "log file exists and has content") or diag "expected $log";

my $seen_assert = 0;
if (-f $log) {
    open my $lfh, '<', $log or die $!;
    while (my $line = <$lfh>) {
        chomp $line;
        next unless length $line;
        my $event = decode_json($line);
        my $fd    = $event->{facet_data};
        $seen_assert++ if $fd && $fd->{assert};
    }
    close $lfh;
}
ok($seen_assert, "at least one assertion event captured by harness-side logger");

# Clean shutdown.
$spawn->terminate;
$spawn->wait;
ok(!kill(0, $spawn->pid), "harness process exited");

done_testing;
