use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Fcntl qw/:mode/;

use App::Yath2::Util::IPC qw/write_ipc_file read_ipc_file unlink_ipc_file/;

my $dir  = tempdir(CLEANUP => 1);
my $path = File::Spec->catfile($dir, 'fakeproj-u-test-20260101-000000-yath-1-ipc.json');

my %payload = (
    yath_version => '2.000011',
    command      => 'test',
    project      => 'fakeproj',
    stamp        => '20260101-000000',
    hostname     => 'h',
    user         => 'u',
    pid          => 1,
    uuid         => 'aabbccdd',
    created_at   => 1714000000,
    workdir      => '/tmp/yath-aabbccdd',
    ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/tmp/yath-aabbccdd/ipc.fifo"]',
);

# write
write_ipc_file($path, \%payload);
ok(-f $path, 'file exists after write');

my $mode = (stat $path)[2] & 07777;
is(sprintf('%04o', $mode), '0600', 'permissions are 0600');

ok(!-e "${path}.pend", 'no leftover .pend');

# read round-trip
my $got = read_ipc_file($path);
is($got, \%payload, 'read returns identical payload');

# unlink with matching pid
unlink_ipc_file($path, $$);
ok(!-e $path, 'unlink with matching pid removed file');

# unlink missing-file is a no-op
ok(lives { unlink_ipc_file($path, $$) }, 'unlink missing file is a no-op');

# unlink with non-matching pid leaves file alone.
write_ipc_file($path, \%payload);
my $other_pid = $$ + 100_000;
unlink_ipc_file($path, $other_pid);
ok(-e $path, 'unlink with mismatched pid does NOT remove file');
unlink $path;

# Hostile umask must not strip owner bits. A umask of 0277 would
# otherwise sysopen-create the file as 0400 (no owner-write), which
# defeats unlink-on-cleanup. write_ipc_file masks group/other only.
{
    my $hostile_path = File::Spec->catfile($dir, 'fakeproj-u-test-20260101-000000-yath-2-ipc.json');
    my $old          = umask 0277;
    write_ipc_file($hostile_path, \%payload);
    umask $old;

    my $hmode = (stat $hostile_path)[2] & 07777;
    is(sprintf('%04o', $hmode), '0600',
        'permissions are 0600 even under hostile umask 0277');
    unlink $hostile_path;
}

# Other-readable group/other bits never appear on the file.
{
    my $other_path = File::Spec->catfile($dir, 'fakeproj-u-test-20260101-000000-yath-3-ipc.json');
    write_ipc_file($other_path, \%payload);
    my $omode = (stat $other_path)[2] & 07777;
    is(($omode & 0077), 0, 'no group or other bits set on IPC info file');
    unlink $other_path;
}

done_testing;
