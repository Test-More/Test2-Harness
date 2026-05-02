use Test2::V0;
use File::Temp qw/tempdir/;
use File::Spec();
use Sys::Hostname qw/hostname/;

use App::Yath2::Util::IPC qw/publish_ipc_file read_ipc_file/;

# ---- Mocks -------------------------------------------------------------------

package MockGroup {
    sub new { my ($class, %v) = @_; return bless {%v} => $class; }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY';
        return $_[0]->{$m};
    }
}

package MockSettings {
    sub new {
        my ($class, %g) = @_;
        return bless {map { $_ => MockGroup->new(%{$g{$_}}) } keys %g} => $class;
    }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY';
        return $_[0]->{$m};
    }
}

package MockSpawn {
    sub new {
        my ($class, %v) = @_;
        return bless {%v} => $class;
    }
    sub pid       { $_[0]->{pid} }
    sub ipcm_info { $_[0]->{ipcm_info} }
}

package main;

my $ipc_dir = tempdir(CLEANUP => 1);
my $work    = tempdir(CLEANUP => 1);

sub make_settings {
    my %ipc_overrides = @_;
    return MockSettings->new(
        yath => {
            instance_uuid    => 'a1b2c3d4',
            base_dir         => '/some/project',
            project          => 'fakeproj',
            user             => 'fakeuser',
            cwd              => $ipc_dir,
            user_config_file => '',
            config_file      => '',
        },
        ipc => {
            file      => undef,
            dir       => $ipc_dir,
            dir_order => [qw/cwd tempdir/],
            %ipc_overrides,
        },
    );
}

sub make_spawn {
    return MockSpawn->new(
        pid       => 99999,
        ipcm_info => '["IPC::Manager::Client::AtomicPipe","IPC::Manager::Serializer::JSON","/tmp/yath-a1b2c3d4/ipc.fifo"]',
    );
}

# ---- 1. test command path: dir-resolution branch ----------------------------

{
    my $settings = make_settings();
    my $spawn    = make_spawn();

    my $path = publish_ipc_file(
        command  => 'test',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $work,
    );

    ok(-f $path, 'file written at returned path');
    like(
        $path,
        qr{\Q$ipc_dir\E/fakeproj-fakeuser-test-\d{8}-\d{6}-yath-99999-ipc\.json\z},
        'path matches new ${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json shape',
    );

    my $rec = read_ipc_file($path);
    is($rec->{command},   'test',          'command stored');
    is($rec->{project},   'fakeproj',      'project from settings->yath->project');
    like($rec->{stamp}, qr/^\d{8}-\d{6}$/, 'stamp matches YYYYMMDD-HHMMSS shape');
    is($rec->{uuid},      'a1b2c3d4',      'uuid from settings');
    is($rec->{pid},       99999,           'pid from spawn');
    is($rec->{ipcm_info}, $spawn->ipcm_info, 'ipcm_info from spawn');
    is($rec->{workdir},   $work,           'workdir as supplied');
    is($rec->{hostname},  hostname(),      'hostname is local hostname');
    is($rec->{user},      'fakeuser',      'user from settings->yath->user');
    ok($rec->{created_at} > 0, 'created_at populated');
    ok($rec->{yath_version},   'yath_version populated');
    ok(!exists $rec->{type},   'no legacy "type" field in payload');

    my $mode = (stat $path)[2] & 07777;
    is(sprintf('%04o', $mode), '0600', 'file is 0600');

    unlink $path;
}

# ---- 2. start command round-trips through filename + body --------------------

{
    my $settings = make_settings();
    my $spawn    = make_spawn();

    my $path = publish_ipc_file(
        command  => 'start',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $work,
    );

    like(
        $path,
        qr{\Q$ipc_dir\E/fakeproj-fakeuser-start-\d{8}-\d{6}-yath-99999-ipc\.json\z},
        'start command in filename',
    );
    my $rec = read_ipc_file($path);
    is($rec->{command}, 'start', 'start command in body');
    unlink $path;
}

# ---- 3. explicit --ipc-file overrides discovery ------------------------------

{
    my $explicit = File::Spec->catfile($ipc_dir, 'my-explicit-path');
    my $settings = make_settings(file => $explicit);
    my $spawn    = make_spawn();

    my $path = publish_ipc_file(
        command  => 'test',
        settings => $settings,
        spawn    => $spawn,
        workdir  => $work,
    );

    is($path, $explicit, 'returned path is the explicit override');
    ok(-f $explicit, 'file written at explicit path, not in dir-resolution location');
    unlink $explicit;
}

# ---- 4. argument validation --------------------------------------------------

{
    my $settings = make_settings();
    my $spawn    = make_spawn();

    like(
        dies { publish_ipc_file(settings => $settings, spawn => $spawn, workdir => $work) },
        qr/'command' is required/,
        'missing command dies',
    );
    like(
        dies { publish_ipc_file(command => 'test', spawn => $spawn, workdir => $work) },
        qr/'settings' is required/,
        'missing settings dies',
    );
    like(
        dies { publish_ipc_file(command => 'test', settings => $settings, workdir => $work) },
        qr/'spawn' is required/,
        'missing spawn dies',
    );
    like(
        dies { publish_ipc_file(command => 'test', settings => $settings, spawn => $spawn) },
        qr/'workdir' is required/,
        'missing workdir dies',
    );
}

done_testing;
