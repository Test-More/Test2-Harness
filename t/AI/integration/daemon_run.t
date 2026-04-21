use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Cwd ();
use Time::HiRes qw/sleep/;

# `yath run` submits tests to a running daemon and follows them to
# completion. This test starts a daemon, runs a passing test plus a
# failing test, and verifies the exit codes + banners.

my $orig = Cwd::getcwd();
my $cwd  = tempdir(CLEANUP => 1);
chdir $cwd or die "chdir: $!";

my $root = $orig;
my $lib  = "$root/lib";
my $tlib = "$root/t/lib";

# Write two tests into the isolated cwd.
my $pass_t = File::Spec->catfile($cwd, 'pass.t');
my $fail_t = File::Spec->catfile($cwd, 'fail.t');
open my $p, '>', $pass_t or die $!;
print {$p} "use Test2::V0; ok(1); done_testing;\n";
close $p;
open my $f, '>', $fail_t or die $!;
print {$f} "use Test2::V0; ok(0, 'deliberate fail'); done_testing;\n";
close $f;

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
    my $pid  = open my $fh, '-|', @cmdv;
    die "fork: $!" unless defined $pid;
    my $out = do { local $/; <$fh> };
    close $fh;
    return {stdout => $out, exit => $? >> 8};
}

my $res = yath_run('start');
is($res->{exit}, 0, 'start exits 0') or diag $res->{stdout};
my ($daemon_pid) = $res->{stdout} =~ /pid:\s+(\d+)/;
ok($daemon_pid, 'got daemon pid');

sleep 0.5;

# Submit a passing run.
$res = yath_run('run', $pass_t);
is($res->{exit}, 0, 'run pass exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/pass=1 fail=0/, 'pass=1 fail=0 banner');

# Submit a failing run.
$res = yath_run('run', $fail_t);
is($res->{exit}, 1, 'run fail exits 1') or diag $res->{stdout};
like($res->{stdout}, qr/pass=0 fail=1/, 'pass=0 fail=1 banner');

# Cleanup.
$res = yath_run('kill');
is($res->{exit}, 0, 'kill exits 0') or diag $res->{stdout};

chdir $orig or die "chdir back: $!";

done_testing;
