use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec ();
use Cwd ();
use Time::HiRes qw/sleep/;

# Exercise the attached-command set: status, ping, ps, resources,
# abort, reload, kill. Each runs against a daemon the test starts
# via yath_run('start') in a fresh cwd.

my $orig = Cwd::getcwd();
my $cwd  = tempdir(CLEANUP => 1);
chdir $cwd or die "chdir: $!";

my $root = $orig;
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

# status
$res = yath_run('status');
is($res->{exit}, 0, 'status exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/Daemon:/,        'status prints Daemon header');
like($res->{stdout}, qr/state:\s+running/, 'state=running');

# ping
$res = yath_run('ping');
is($res->{exit}, 0, 'ping exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/ping 1 ok/, 'ping ok line');

# ps
$res = yath_run('ps');
is($res->{exit}, 0, 'ps exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/PID\s+TYPE\s+ROLE\s+NAME/, 'ps table header');
like($res->{stdout}, qr/harness/, 'ps includes harness');

# resources
$res = yath_run('resources');
is($res->{exit}, 0, 'resources exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/\[global\]/, 'resources shows global scope');
like($res->{stdout}, qr/jobcount/,   'resources lists jobcount');

# abort (nothing queued; should be a friendly no-op)
$res = yath_run('abort');
is($res->{exit}, 0, 'abort exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/No active runs to abort/, 'abort no-op message');

# reload (no preloads attached; should return an empty reloaded list)
$res = yath_run('reload');
is($res->{exit}, 0, 'reload exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/No preload resources/, 'reload no-op message');

# kill
$res = yath_run('kill');
is($res->{exit}, 0, 'kill exits 0') or diag $res->{stdout};
like($res->{stdout}, qr/daemon terminated/, 'kill confirms termination');
ok(!kill(0, $daemon_pid), 'daemon process gone');

chdir $orig or die "chdir back: $!";

done_testing;
