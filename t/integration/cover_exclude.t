use Test2::V0;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Require::Module 'Test2::Plugin::Cover' => '0.000030';
use Test2::Require::AuthorTesting;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util qw/clean_path/;
use Test2::Util qw/CAN_REALLY_FORK/;
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

# The coverage facet itself is collapsed before it is logged, so the file map
# consumers see is what yath adds: job_coverage per job, or run_coverage at
# the end, depending on the aggregator.
sub event_files {
    my ($log) = @_;

    my %files;
    for my $event (log_events($log)) {
        my $fd = $event->{facet_data};
        for my $cov (grep { $_ } $fd->{job_coverage}, $fd->{run_coverage}) {
            @files{keys %{$cov->{files}}} = values %{$cov->{files}};
        }
    }

    return fixture_files(\%files);
}

sub log_events {
    my ($log) = @_;

    my @out;
    my @events = $log->poll();
    while (@events) {
        my $event = shift @events;
        push @out    => $event if $event;
        push @events => $log->poll;
    }

    return @out;
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
    skip_all "Cannot fork, skipping preload test" if $ENV{T2_NO_FORK} || !CAN_REALLY_FORK;

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

# Coverage produced by a process yath did not launch cannot carry the
# exclusions, so it is filtered again where every coverage event is seen.
subtest out_of_band_producer => sub {
    my $oob = "$dir" . "_out_of_band";

    my ($fh, $cfile) = tempfile("cover-exclude-oob-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.json');
    close($fh);

    yath(
        command => 'test',
        pre     => ["-D$oob/lib"],
        log     => 1,
        args    => [
            "-I$oob/lib", $oob, '--ext=tx', '-v',
            '-p+CoverExcludePeek',
            '--cover-files',
            "--cover-write=$cfile",
            "--cover-exclude-dirs=$oob/deps",
        ],
        exit => 0,
        test => sub {
            my $out = shift;

            open(my $rfh, '<', $cfile) or die "Could not open coverage file '$cfile': $!";
            my $data  = decode_json(join '' => <$rfh>);
            my @files = sort keys %{$data->{files} // {}};

            ok(
                (grep { m{OOBKeep\.pm$} } @files),
                "Kept a source file the test itself covered",
            ) or diag(join ", " => @files);

            is(
                [grep { m{OOBDep\.pm$} } @files],
                [],
                "Dropped every descendant's coverage of the excluded tree",
            ) or diag(join ", " => @files);

            # A producer's keys are relative to its own root and are left as
            # reported; the root is used only to resolve them for exclusion.
            ok(
                (grep { $_ eq 'lib/OOBRekey.pm' } @files),
                "A descendant with its own root keeps its own keys",
            ) or diag(join ", " => @files);

            ok(
                (grep { $_ eq 'OOBOutside.pm' } @files),
                "A descendant measured outside the project is not dropped",
            ) or diag(join ", " => @files);

            like(
                $out->{output},
                qr{COVERAGE FACET: files=SCALAR file_count=\d+},
                "Coverage facet reaching consumers carries counts, not the file map",
            );

            my @raw = grep { $_->{facet_data}->{coverage} } log_events($out->{log});
            ok(@raw, "Found coverage facets in the log");
            is(
                [grep { ref($_->{facet_data}->{coverage}->{files}) } @raw],
                [],
                "The logged coverage facets are the collapsed ones",
            );
        },
    );

    # Without this the assertion above could pass because the descendant never
    # reached the event stream at all.
    my ($fh2, $cfile2) = tempfile("cover-exclude-oob-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.json');
    close($fh2);

    yath(
        command => 'test',
        args    => ["-I$oob/lib", $oob, '--ext=tx', '-v', '--cover-files', "--cover-write=$cfile2"],
        exit    => 0,
        test    => sub {
            open(my $rfh, '<', $cfile2) or die "Could not open coverage file '$cfile2': $!";
            my $data  = decode_json(join '' => <$rfh>);
            my @files = sort keys %{$data->{files} // {}};

            ok(
                (grep { m{OOBDep\.pm$} } @files),
                "Without the exclusion the descendant's coverage is recorded",
            ) or diag(join ", " => @files);
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
