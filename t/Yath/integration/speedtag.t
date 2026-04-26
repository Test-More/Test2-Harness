# HARNESS-CONFLICTS YATH
# HARNESS-DURATION-MODERATE
use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use File::Copy qw/copy/;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;
use App::Yath2::Util qw/find_yath/;
find_yath();    # cache result before we chdir

# Each scenario walks `yath speedtag` over a different shape of log
# input. They cover the delta this branch landed on top of origin/2.0:
#
#   * Command::speedtag drives every input through
#     Streamer::Static -- LogArchive recognises both directories
#     and .yath archives, so the dispatch is just "open the path".
#   * Streamer::Static drops the archive's bundled zstd-dict at
#     the extraction tempdir root (covered indirectly by every
#     archive scenario when the harness picks up a dict from
#     share).
#   * App::Yath2::LogArchive::Directory exposes dict_bytes (via
#     Role::DiskDict, covered by the directory-input scenario
#     that uses `yath extract`).

my $fixtures = __FILE__;
$fixtures =~ s{\.t$}{}g;
$fixtures =~ s{^\./}{};

# Copy pass.tx + pass2.tx into a fresh tempdir so each scenario gets
# untagged inputs (speedtag mutates the .tx files in place).
sub fresh_fixtures {
    my $tmp   = tempdir(CLEANUP => 1);
    my $pass  = File::Spec->catfile($tmp, 'pass.tx');
    my $pass2 = File::Spec->catfile($tmp, 'pass2.tx');
    copy(File::Spec->catfile($fixtures, 'pass.tx'),  $pass);
    copy(File::Spec->catfile($fixtures, 'pass2.tx'), $pass2);
    return ($tmp, $pass, $pass2);
}

# Verify each fixture file ends up with a HARNESS-DURATION-* header.
sub assert_tagged {
    my ($label, @files) = @_;
    for my $file (@files) {
        open(my $fh, '<', $file) or die "open '$file': $!";
        my $found = 0;
        while (my $line = <$fh>) {
            chomp $line;
            next unless $line =~ m/^#\s*HARNESS-DURATION-(SHORT|MEDIUM|LONG)$/;
            $found = 1;
            last;
        }
        close $fh;
        my ($base) = $file =~ m{(pass\d?\.tx)$};
        ok($found, "$label: tagged $base");
    }
}

subtest 'speedtag from the archive path Tester `log => 1` produces' => sub {
    my ($tmp, $pass, $pass2) = fresh_fixtures();

    my $out = yath(command => 'test', args => [$tmp, '--ext=tx'], log => 1, exit => 0);
    my $log = $out->{log}->name;

    yath(
        command => 'speedtag',
        args    => [$log],
        exit    => 0,
        test    => sub {
            like($_, qr/Tagged .*pass\.tx/,  'announced pass.tx');
            like($_, qr/Tagged .*pass2\.tx/, 'announced pass2.tx');
            assert_tagged('Tester log => 1', $pass, $pass2);
        },
    );
};

subtest 'speedtag from an explicit *.yath archive path' => sub {
    my ($tmp, $pass, $pass2) = fresh_fixtures();
    my $archive = File::Spec->catfile($tmp, 'run.yath');

    yath(
        command => 'test',
        args    => [$tmp, '--ext=tx', "--log-file=$archive"],
        exit    => 0,
    );
    ok(-f $archive, '--log-file produced an archive at the requested path');

    yath(
        command => 'speedtag',
        args    => [$archive],
        exit    => 0,
        test    => sub {
            like($_, qr/Tagged .*pass\.tx/,  'announced pass.tx');
            like($_, qr/Tagged .*pass2\.tx/, 'announced pass2.tx');
            assert_tagged('yath archive', $pass, $pass2);
        },
    );
};

subtest 'speedtag from an extracted live $logdir directory' => sub {
    my ($tmp, $pass, $pass2) = fresh_fixtures();
    my $archive = File::Spec->catfile($tmp, 'run.yath');
    my $logdir  = File::Spec->catdir($tmp, 'extracted');

    yath(
        command => 'test',
        args    => [$tmp, '--ext=tx', "--log-file=$archive"],
        exit    => 0,
    );
    yath(command => 'extract', args => [$archive, $logdir], exit => 0);
    ok(-d $logdir, 'extract produced a directory');

    yath(
        command => 'speedtag',
        args    => [$logdir],
        exit    => 0,
        test    => sub {
            like($_, qr/Tagged .*pass\.tx/,  'announced pass.tx');
            like($_, qr/Tagged .*pass2\.tx/, 'announced pass2.tx');
            assert_tagged('directory backend', $pass, $pass2);
        },
    );
};

subtest 'speedtag errors cleanly on a missing log path' => sub {
    my $tmp     = tempdir(CLEANUP => 1);
    my $missing = File::Spec->catfile($tmp, 'no-such.yath');
    ok(!-e $missing, 'precondition: log path does not exist');

    yath(
        command => 'speedtag',
        args    => [$missing],
        exit    => T(),
        test    => sub {
            like($_, qr{Log source.*does not exist}, 'reported a missing-source error');
        },
    );
};

done_testing;
