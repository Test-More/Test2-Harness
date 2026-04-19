use Test2::V0;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2;

my $dir = tempdir(CLEANUP => 1);

# Tiny test file.
my $test_file = "$dir/ok.t";
open my $fh, '>', $test_file or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $spawn = Test2::Harness2->spawn(workdir => $dir);
isa_ok($spawn, ['Test2::Harness2::Spawn']);
ok($spawn->pid,          'has pid');
ok(kill(0, $spawn->pid), 'service is alive');

my $tf     = Test2::Harness2::TestFile->new(file => $test_file);
my $queued = $spawn->queue_test_run(files => [$tf]);
ok($queued->{ok}, 'queued') or diag explain $queued;

# Poll for completion.
my $done;
for (1 .. 200) {
    my $status = $spawn->status;
    if (!@{$status->{running} // []} && scalar(@{$status->{queue}}) == 0) {
        $done = 1;
        last;
    }
    sleep(0.05);
}
ok($done, 'run completed within 10s') or diag "still running after 10s";

my $fin = $spawn->finish;
ok($fin->{ok}, 'finish accepted');

$spawn->wait;
ok(!kill(0, $spawn->pid), 'service exited');

done_testing;
