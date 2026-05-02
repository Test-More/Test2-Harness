use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Sys::Hostname qw/hostname/;

use App::Yath2::Util::IPC qw/write_ipc_file find_ipc_files resolve_ipc_filename/;

my $dir  = tempdir(CLEANUP => 1);
my $host = hostname();

# Write three files: two on local host, one on a foreign host.
my @records = (
    {
        yath_version => '2.000011', command => 'test',  hostname => $host,   user => 'u',
        project      => 'fakeproj', stamp   => '20260101-000001',
        pid          => $$,         uuid    => 'aaaaaaaa', created_at => 1000,
        workdir      => '/x',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p1"]',
    },
    {
        yath_version => '2.000011', command => 'start', hostname => $host,   user => 'u',
        project      => 'fakeproj', stamp   => '20260101-000002',
        pid          => $$,         uuid    => 'bbbbbbbb', created_at => 2000,
        workdir      => '/x',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p2"]',
    },
    {
        yath_version => '2.000011', command => 'test',  hostname => 'other-host', user => 'u',
        project      => 'fakeproj', stamp   => '20260101-000003',
        pid          => 999_999_998, uuid    => 'cccccccc', created_at => 3000,
        workdir      => '/x',
        ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p3"]',
    },
);

for my $r (@records) {
    my $name = resolve_ipc_filename(
        project => $r->{project},
        user    => $r->{user},
        command => $r->{command},
        stamp   => $r->{stamp},
        pid     => $r->{pid},
    );
    write_ipc_file(File::Spec->catfile($dir, $name), $r);
}

# Default filter (live + local host) drops the foreign-host entry.
my $list = find_ipc_files(dirs => [$dir]);
is(scalar @$list, 2, 'default filter drops cross-host entry');
is($list->[0]{uuid}, 'bbbbbbbb', 'sorted newest first');

# command filter
$list = find_ipc_files(dirs => [$dir], command => 'start');
is(scalar @$list, 1, 'command filter keeps only start');
is($list->[0]{uuid}, 'bbbbbbbb');

# host => undef disables host filter, includes cross-host
$list = find_ipc_files(dirs => [$dir], host => undef);
is(scalar @$list, 3, 'host => undef returns all');

# Dead pid local entry should be dropped + unlinked
my $dead = {
    yath_version => '2.000011', command => 'test', hostname => $host, user => 'u',
    project      => 'fakeproj', stamp   => '20260101-000004',
    pid          => 999_999_999, uuid   => 'deaddead', created_at => 500,
    workdir      => '/x',
    ipcm_info    => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/p4"]',
};
my $dead_name = resolve_ipc_filename(
    project => $dead->{project},
    user    => $dead->{user},
    command => $dead->{command},
    stamp   => $dead->{stamp},
    pid     => $dead->{pid},
);
my $dead_path = File::Spec->catfile($dir, $dead_name);
write_ipc_file($dead_path, $dead);

$list = find_ipc_files(dirs => [$dir]);
ok(!grep({ $_->{uuid} eq 'deaddead' } @$list), 'dead-pid local entry filtered');
ok(!-e $dead_path, 'dead-pid local entry unlinked');

done_testing;
