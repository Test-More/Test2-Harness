use Test2::V0;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Require::Module 'Test2::Plugin::Cover' => '0.000029';
use Test2::Require::AuthorTesting;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util qw/clean_path/;
use File::Spec();

use File::Temp qw/tempfile/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Coverage paths are relative to the run root, so every comparison below needs
# this to be relative too, however the file was invoked.
$dir = File::Spec->abs2rel($dir) if File::Spec->file_name_is_absolute($dir);

my $abs_dir = clean_path($dir);

my $KEEP   = "$dir/lib/Keep.pm";
my $DEP    = "$dir/deps/lib/Dep.pm";
my $DEP2   = "$dir/deps2/Dep2.pm";
my $VENDOR = "$dir/vendor/Vendor.pm";

# Every run also covers harness modules under lib/, which are not what this
# file is about. Only the fixture tree is compared.
sub fixture_files {
    my ($files) = @_;
    return [sort grep { m{^\Q$dir\E/} && m{\.pm$} } keys %{$files // {}}];
}

sub event_files {
    my ($log) = @_;

    my %files;
    my @events = $log->poll();
    while (@events) {
        my $event = shift @events;
        if ($event) {
            my $cov = $event->{facet_data}->{coverage};
            @files{keys %{$cov->{files}}} = values %{$cov->{files}} if $cov;
        }

        push @events => $log->poll;
    }

    return fixture_files(\%files);
}

sub written_files {
    my ($cfile) = @_;

    open(my $fh, '<', $cfile) or die "Could not open coverage file '$cfile': $!";
    my $data = decode_json(join '' => <$fh>);

    return fixture_files($data->{files});
}

sub cover_run {
    my %params = @_;

    my ($fh, $cfile) = tempfile("cover-exclude-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.json');
    close($fh);

    my $out = yath(
        command => 'test',
        log     => 1,
        args    => [
            "-I$dir/lib", $dir, '--ext=tx', '-v',
            "--cover-write=$cfile",
            @{$params{args} // []},
        ],
        exit => 0,
        test => sub {
            my $out = shift;

            like($out->{output}, qr{PRELOAD: \Q$params{preload}\E$}m, "Ran under the expected transport")
                if defined $params{preload};

            is(event_files($out->{log}), $params{expect}, "Coverage event has the expected files");
            is(written_files($cfile),    $params{expect}, "Aggregated run data has the expected files");

            $params{test}->($out) if $params{test};
        },
    );

    return $out;
}

subtest no_exclusions => sub {
    cover_run(
        preload => 0,
        expect  => [sort($DEP, $DEP2, $KEEP, $VENDOR)],
    );
};

subtest one_exclusion => sub {
    cover_run(
        preload => 0,
        args    => ["--cover-exclude-dirs=$dir/deps"],
        expect  => [sort($DEP2, $KEEP, $VENDOR)],
    );
};

subtest multiple_exclusions => sub {
    cover_run(
        preload => 0,
        args    => ["--cover-exclude-dirs=$dir/deps", "--cover-exclude-dir=$dir/vendor"],
        expect  => [sort($DEP2, $KEEP)],
    );
};

subtest path_needing_normalization => sub {
    cover_run(
        preload => 0,
        args    => ["--cover-exclude-dirs=./$dir/vendor/../deps/lib/.."],
        expect  => [sort($DEP2, $KEEP, $VENDOR)],
    );
};

subtest wildcard_exclusion => sub {
    cover_run(
        preload => 0,
        args    => ["--cover-exclude-dirs=$dir/deps*"],
        expect  => [sort($KEEP, $VENDOR)],
    );
};

subtest preload => sub {
    cover_run(
        preload => 1,
        args    => ['-PCoverExcludePreload', "--cover-exclude-dirs=$dir/deps", "--cover-exclude-dirs=$dir/vendor"],
        expect  => [sort($DEP2, $KEEP)],
    );
};

# --cover-dirs picks the files metrics are calculated over, and exclusions are
# subtracted from that set, so an excluded file is counted in neither the
# totals nor the untested list.
subtest metrics => sub {
    cover_run(
        expect => [sort($DEP, $DEP2, $KEEP, $VENDOR)],
        args   => ['--cover-metrics', '--no-cover-dirs', "--cover-dirs=$dir"],
        test   => sub {
            my $out = shift;
            like($out->{output}, qr{^\|\s*files\s*\|\s*5\s*\|\s*4\s*\|}m, "All 5 fixture modules counted, 4 tested");
            like($out->{output}, qr{^\|\s*subs\s*\|\s*4\s*\|\s*4\s*\|}m,  "All 4 fixture subs counted and tested");
        },
    );

    cover_run(
        expect => [sort($DEP2, $KEEP, $VENDOR)],
        args   => ['--cover-metrics', '--no-cover-dirs', "--cover-dirs=$dir", "--cover-exclude-dirs=$dir/deps"],
        test   => sub {
            my $out = shift;
            like($out->{output}, qr{^\|\s*files\s*\|\s*4\s*\|\s*3\s*\|}m, "Excluded module dropped from the total");
            like($out->{output}, qr{^\|\s*subs\s*\|\s*3\s*\|\s*3\s*\|}m,  "Excluded sub dropped from the total");
        },
    );
};

subtest exclusions_in_verbose_output => sub {
    yath(
        command => 'test',
        args    => ["-I$dir/lib", $dir, '--ext=tx', '-vv', '--cover-files', "--cover-exclude-dirs=$dir/deps"],
        exit    => 0,
        test    => sub {
            my $out = shift;

            like($out->{output}, qr{RUN INFO.*"exclude",},          "Verbose output shows the exclusion parameter");
            like($out->{output}, qr{RUN INFO.*"\Q$abs_dir\E/deps"}, "Verbose output shows the normalized exclusion path");
        },
    );
};

subtest comma_is_rejected => sub {
    yath(
        command => 'test',
        args    => ["-I$dir/lib", $dir, '--ext=tx', '--cover-files', "--cover-exclude-dirs=$dir/deps,$dir/vendor"],
        exit    => T(),
        test    => sub {
            my $out = shift;

            like(
                $out->{output},
                qr{--cover-exclude-dirs cannot use a path containing a comma},
                "Rejected the path and said why",
            );

            like(
                $out->{output},
                qr{'\Q$abs_dir\E/deps,},
                "Checked the resolved path, not the value as typed",
            );
        },
    );
};

done_testing;
