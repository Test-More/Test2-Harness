use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Cwd ();
use Time::HiRes qw/sleep/;

# End-to-end smoke for `yath start` + `yath stop`. We launch each
# command in its own child perl process (via fork+exec of
# scripts/yath-like logic) so the daemon ends up properly detached
# and the stop command sees it as a long-running orphan.

my $orig = Cwd::getcwd();
my $cwd  = tempdir(CLEANUP => 1);
chdir $cwd or die "chdir: $!";

my $root = $orig;    # the worktree root (where we cd'd from)
my $lib  = "$root/lib";
my $tlib = "$root/t/lib";

sub yath_run {
    my ($cmd, @args) = @_;
    my $script = <<"PERL";
use lib '$lib';
use lib '$tlib';
require App::Yath2::Command::$cmd;
my \$obj = App::Yath2::Command::$cmd->new(
    script => 'yath',
    argv   => [\@ARGV],
);
exit(\$obj->run);
PERL

    my @cmdv = ($^X, '-e', $script, '--', @args);

    # Use open3-style list-form so we don't have to worry about shell
    # quoting of the script body.
    my $pid = open my $fh, '-|', @cmdv;
    die "fork: $!" unless defined $pid;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $exit = $? >> 8;
    return {stdout => $out, exit => $exit};
}

# Start a daemon in a separate process so its lifetime is not tied
# to our own test process.
my $res = yath_run('start');
is($res->{exit}, 0, 'start exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/yath daemon started/, 'banner printed');
my ($pid)     = $res->{stdout} =~ /pid:\s+(\d+)/;
my ($workdir) = $res->{stdout} =~ /workdir:\s+(\S+)/;
ok($pid && $pid > 0,        'captured pid') or diag $res->{stdout};
ok($workdir && -d $workdir, 'captured workdir and it exists');

my $cwd_pointer = File::Spec->catfile($cwd, '.yath-daemon.json');
my $wd_pointer  = File::Spec->catfile($workdir, 'daemon.json');
ok(-f $cwd_pointer, 'cwd pointer written');
ok(-f $wd_pointer,  'workdir pointer written');

# Give the daemon a moment to settle.
sleep 0.5;
ok(kill(0, $pid), 'daemon is alive');

# Stop: ask the daemon to drain + waits for exit.
$res = yath_run('stop');
is($res->{exit}, 0, 'stop exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/daemon exited/, 'stop reported exit');

# Pointer files should be cleaned up by stop.
ok(!-f $cwd_pointer, 'cwd pointer removed');

# Process should be gone.
ok(!kill(0, $pid), 'daemon process gone');

chdir $orig or die "chdir back: $!";

done_testing;
