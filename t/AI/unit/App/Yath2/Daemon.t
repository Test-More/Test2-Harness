use Test2::V0;
use File::Temp qw/tempdir/;
use Cwd ();
use File::Spec ();

use App::Yath2::Daemon;

my $wd = tempdir(CLEANUP => 1);

subtest write_and_read_workdir_pointer => sub {
    my $orig = Cwd::getcwd();
    my $cwd  = tempdir(CLEANUP => 1);
    chdir $cwd or die "chdir: $!";

    my $written = App::Yath2::Daemon::write_pointer(
        workdir   => $wd,
        pid       => 12345,
        ipcm_info => {socket => '/tmp/fake'},
        name      => 'harness',
    );

    ok(ref($written) eq 'ARRAY' && @$written >= 1, 'write_pointer returns list');

    my $wd_path  = File::Spec->catfile($wd, 'daemon.json');
    my $cwd_path = File::Spec->catfile($cwd, '.yath-daemon.json');

    ok(-f $wd_path,  'workdir pointer exists');
    ok(-f $cwd_path, 'cwd pointer exists');

    my $data = App::Yath2::Daemon::read_pointer($wd_path);
    is($data->{pid},       12345, 'pid round-trips');
    is($data->{workdir},   $wd,   'workdir round-trips');
    is($data->{name},      'harness', 'name round-trips');
    is($data->{ipcm_info}, {socket => '/tmp/fake'}, 'ipcm_info round-trips');

    chdir $orig or die "chdir back: $!";
};

subtest discover_by_env => sub {
    my $wd2 = tempdir(CLEANUP => 1);
    App::Yath2::Daemon::write_pointer(
        workdir        => $wd2,
        pid            => 99,
        ipcm_info      => {socket => '/tmp/also-fake'},
        name           => 'harness',
        no_cwd_pointer => 1,
    );

    local $ENV{YATH_DAEMON_WORKDIR} = $wd2;

    my ($data, $path) = App::Yath2::Daemon::discover_pointer();
    is($data->{pid},     99,  'discovered pid');
    is($data->{workdir}, $wd2, 'discovered workdir');
    like($path, qr/\Q$wd2\E/, 'path under the workdir');
};

subtest discover_by_cwd => sub {
    my $orig = Cwd::getcwd();
    my $wd3  = tempdir(CLEANUP => 1);
    my $cwd  = tempdir(CLEANUP => 1);
    chdir $cwd or die "chdir: $!";

    App::Yath2::Daemon::write_pointer(
        workdir   => $wd3,
        pid       => 77,
        ipcm_info => {socket => '/tmp/cwd-fake'},
        name      => 'harness',
    );

    local %ENV = %ENV;
    delete $ENV{YATH_DAEMON_WORKDIR};
    my ($data, $path) = App::Yath2::Daemon::discover_pointer();
    is($data->{pid},     77,  'discovered pid');
    is($data->{workdir}, $wd3, 'discovered workdir');

    chdir $orig or die "chdir back: $!";
};

subtest discover_missing => sub {
    my $orig = Cwd::getcwd();
    my $cwd  = tempdir(CLEANUP => 1);
    chdir $cwd or die "chdir: $!";

    local %ENV = %ENV;
    delete $ENV{YATH_DAEMON_WORKDIR};
    my $err;
    my $ok = eval { App::Yath2::Daemon::discover_pointer(); 1 };
    $err = $@;
    ok(!$ok, 'discovery fails with no pointer');
    like($err, qr/no yath daemon found/, 'informative error');

    chdir $orig or die "chdir back: $!";
};

subtest remove_pointers_guards_mismatched_cwd => sub {
    my $orig = Cwd::getcwd();
    my $wd4  = tempdir(CLEANUP => 1);
    my $wd5  = tempdir(CLEANUP => 1);
    my $cwd  = tempdir(CLEANUP => 1);
    chdir $cwd or die "chdir: $!";

    # Write the cwd pointer via write_pointer pointing at $wd4.
    App::Yath2::Daemon::write_pointer(
        workdir   => $wd4,
        pid       => 111,
        ipcm_info => {socket => '/tmp/fake-111'},
        name      => 'harness',
    );
    my $cwd_path = File::Spec->catfile($cwd, '.yath-daemon.json');
    ok(-f $cwd_path, 'cwd pointer initially present');

    # Try to remove with workdir = $wd5 (different daemon); should NOT
    # touch the cwd pointer.
    App::Yath2::Daemon::remove_pointers(workdir => $wd5);
    ok(-f $cwd_path, 'cwd pointer retained when workdir mismatches');

    # Remove with the matching workdir; cwd pointer should go.
    App::Yath2::Daemon::remove_pointers(workdir => $wd4);
    ok(!-f $cwd_path, 'cwd pointer removed when workdir matches');

    chdir $orig or die "chdir back: $!";
};

done_testing;
