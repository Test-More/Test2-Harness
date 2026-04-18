use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Preload::Stage;
use Test2::Harness2::Reloader;

# Force the Stat backend for unit testing so behavior does not depend on
# whether Linux::Inotify2 is installed on the host.
use Test2::Harness2::Reloader::Stat;

subtest "factory picks a backend" => sub {
    my $r = Test2::Harness2::Reloader->new(stage => 'demo');
    ok(
        $r->isa('Test2::Harness2::Reloader::Stat')
            || $r->isa('Test2::Harness2::Reloader::Inotify2'),
        "auto-chose a backend"
    );
};

subtest "Stat backend: detect changes" => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, "w.txt");
    open my $fh, '>', $file or die $!;
    print $fh "alpha\n";
    close $fh;

    my $r = Test2::Harness2::Reloader::Stat->new(
        stage        => 'demo',
        min_interval => 0,
    );

    $r->watch($file);
    $r->start;

    # Immediately after start, no changes.
    my $changed = $r->changed_files;
    is($changed, [], "no changes reported initially");

    # Touch the file with a newer mtime.
    sleep 0.2;
    utime(time + 5, time + 5, $file) or die "utime: $!";

    $changed = $r->changed_files;
    ok($changed, "got a changed list");
    is($changed, [File::Spec->rel2abs($file)], "file reported as changed");

    # Next call reports no changes (state advanced).
    $changed = $r->changed_files;
    is($changed, [], "state advanced");

    $r->stop;
};

subtest "find_churn parses markers" => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'F.pm');
    open my $fh, '>', $file or die $!;
    print $fh <<'EOM';
package F;
sub stable { 1 }

# HARNESS-CHURN-START
sub volatile_a { 'a' }
sub volatile_b { 'b' }
# HARNESS-CHURN-STOP

sub stable2 { 2 }

# HARNESS-CHURN-START
sub volatile_c { 'c' }
# HARNESS-CHURN-STOP

1;
EOM
    close $fh;

    my $r = Test2::Harness2::Reloader::Stat->new(stage => 'demo');
    my @churn = $r->find_churn($file);

    is(scalar @churn, 2, "two churn sections");
    like($churn[0]->[1], qr/volatile_a/, "first section has expected contents");
    like($churn[0]->[1], qr/volatile_b/, "first section has both subs");
    like($churn[1]->[1], qr/volatile_c/, "second section has expected contents");
};

subtest "watch requires an existing file" => sub {
    my $r = Test2::Harness2::Reloader::Stat->new(stage => 'demo');
    like(
        dies { $r->watch("/no/such/file", sub { }) },
        qr/must be a file/,
        "missing file rejected"
    );
};

subtest "file_info detects imports and preload marker" => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $exp  = File::Spec->catdir($dir, 'FI');
    File::Path::make_path($exp);

    my $expfile = File::Spec->catfile($exp, 'Export.pm');
    open my $fh, '>', $expfile or die $!;
    print $fh <<'EOPM';
package FI::Export;
use Exporter 'import';
our @EXPORT_OK = ('foo');
sub foo { 1 }
1;
EOPM
    close $fh;

    local @INC = ($dir, @INC);
    require FI::Export;

    my $r = Test2::Harness2::Reloader::Stat->new(stage => 'demo');
    $r->watch($expfile);

    my $info = $r->file_info($expfile);
    is($info->{module},     'FI::Export', "module detected");
    ok($info->{perl},                     "perl flag set");
    ok($info->{has_import},               "exporter import detected");
    ok(!$info->{t2_preload},              "not a preload library");
};

done_testing;
