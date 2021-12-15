use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;
use Test2::Harness::Util qw/clean_path/;

use Test2::Harness::Util::JSON qw/decode_json/;

skip_all "This test is not run under automated testing"
    if $ENV{AUTOMATED_TESTING};

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};
my $fqdir = clean_path($dir);
my $pdir = $fqdir;
$pdir =~ s{\W{0,2}t\W{1,2}integration\W{1,2}reload$}{}g;

my $tmpdir = tempdir(CLEANUP => 1);
mkdir("$tmpdir/Preload") or die "($tmpdir/Preload) $!";

sub touch_files {
    note "About to touch files with a delay between each, this will take a while";

    for my $file (qw/A B A B ExceptionA ExceptionB WarningA WarningB ExporterA ExporterB IncChange Churn nonperl1 nonperl2/) {
        my $path = "$dir/lib/Preload/${file}";
        $path .= '.pm' unless $file =~ m/nonperl/;
        note "Touching $file...";
        sleep 2;

        if ($file eq 'IncChange') {
            open(my $fh, '>', "$tmpdir/Preload/IncChange.pm") or die $!;

            print $fh <<'            EOT';
package Preload::IncChange;
use strict;
use warnings;

BEGIN {
    print "$$ $0 Loaded (DIFFERENT) ${ \__PACKAGE__ }\n";
}

1;
            EOT

            close($fh);
        }

        utime(undef, undef, $path);
    }

    sleep 2;
}

sub parse_output {
    my ($output) = @_;

    my %by_proc;
    for my $line (split /\n/, $output) {
        next unless $line =~ m/^\s*(\d+) yath-nested-runner(?:-(\S+))? - (.+)$/;
        my ($pid, $proc, $text) = ($1, $2, $3);
        $proc //= '';
        $text =~ s/$pid yath-nested-runner-$proc(\s*-\s*)//g;
        $text =~ s{(\Q$fqdir\E|\Q$dir\E|\Q$pdir\E)/*}{}g;
        $text =~ s{\Q$tmpdir\E(/)?}{TEMP$1}g;
        $text =~ s{ line \d+.*$}{}g;
        push @{$by_proc{$proc || 'default'}} => $text;
    }

    return \%by_proc;
}

subtest no_in_place => sub {
    unlink("$tmpdir/Preload/IncChange.pm") if -e "$tmpdir/Preload/IncChange.pm";

    yath(
        command => 'start',
        args    => ['-PPreload'],
        pre     => ["-D$tmpdir"],
        exit    => 0,
    );

    touch_files();

    yath(
        command => 'watch',
        args    => ['STOP'],
        exit    => 0,
        test    => sub {
            my $out = shift;

            my $parsed = parse_output($out->{output});
            is(
                $parsed,
                {
                    'default' => [
                        'Loaded Preload',
                    ],
                    'A' => [
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/nonperl1\' has a reload callback, executing it instead of regular reloading...',
                        'RELOAD CALLBACK nonperl1',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/nonperl2\' has a reload callback, executing it instead of regular reloading...',
                        'RELOAD CALLBACK nonperl2',
                    ],
                    'B' => [
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'blacklisting changed files and reloading stage...',
                    ],
                },
                "Reload happened as expected",
            );
        },
    );

    yath(command => 'stop', exit => 0);
};

subtest in_place => sub {
    unlink("$tmpdir/Preload/IncChange.pm") if -e "$tmpdir/Preload/IncChange.pm";

    yath(
        command => 'start',
        args    => ['-PPreload', '-r'],
        pre     => ["-D$tmpdir"],
        exit    => 0,
    );

    touch_files();

    yath(
        command => 'watch',
        args    => ['STOP'],
        exit    => 0,
        test    => sub {
            my $out = shift;

            my $parsed = parse_output($out->{output});
            is(
                $parsed,
                {
                    'default' => [
                        'Loaded Preload',
                    ],
                    'A' => [
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/A.pm\' in place...',
                        'Loaded Preload::A',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/A.pm\' in place...',
                        'Loaded Preload::A',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/ExceptionA.pm\' in place...',
                        'Loaded Preload::ExceptionA',
                        'Failed to reload \'lib/Preload/ExceptionA.pm\' in place...',
                        'Loaded Preload::ExceptionA again.',
                        'BEGIN failed--compilation aborted at lib/Preload/ExceptionA.pm',
                        'Compilation failed in require at lib/Test2/Harness/Runner/Preloader.pm',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/WarningA.pm\' in place...',
                        'Loaded Preload::WarningA',
                        'Failed to reload \'lib/Preload/WarningA.pm\' in place...',
                        'Loaded Preload::WarningA again.',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::ExporterA',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/ExporterA.pm\' cannot be reloaded in place...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Churn 1',
                        'FOO: foo 1',
                        'Churn 2',
                        'Churn 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/Churn.pm\' contains churn sections, running them instead of a full reload...',
                        'Churn 1',
                        'FOO: foo 2',
                        'Success reloading churn block (lib/Preload/Churn.pm lines 8 -> 16)',
                        'Churn 2',
                        'Success reloading churn block (lib/Preload/Churn.pm lines 18 -> 20)',
                        'Error reloading churn block (lib/Preload/Churn.pm lines 22 -> 28): Died on count 3',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/nonperl1\' has a reload callback, executing it instead of regular reloading...',
                        'RELOAD CALLBACK nonperl1',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/nonperl2\' has a reload callback, executing it instead of regular reloading...',
                        'RELOAD CALLBACK nonperl2',
                    ],
                    'B' => [
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExceptionA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/A.pm\' in place...',
                        'Loaded Preload::A',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/B.pm\' in place...',
                        'Loaded Preload::B',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/A.pm\' in place...',
                        'Loaded Preload::A',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/B.pm\' in place...',
                        'Loaded Preload::B',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/ExceptionA.pm\' in place...',
                        'Loaded Preload::ExceptionA',
                        'Failed to reload \'lib/Preload/ExceptionA.pm\' in place...',
                        'Loaded Preload::ExceptionA again.',
                        'BEGIN failed--compilation aborted at lib/Preload/ExceptionA.pm',
                        'Compilation failed in require at lib/Test2/Harness/Runner/Preloader.pm',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExceptionB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/ExceptionB.pm\' in place...',
                        'Loaded Preload::ExceptionB',
                        'Failed to reload \'lib/Preload/ExceptionB.pm\' in place...',
                        'Loaded Preload::ExceptionB again.',
                        'BEGIN failed--compilation aborted at lib/Preload/ExceptionB.pm',
                        'Compilation failed in require at lib/Test2/Harness/Runner/Preloader.pm',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::WarningA',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/WarningA.pm\' in place...',
                        'Loaded Preload::WarningA',
                        'Failed to reload \'lib/Preload/WarningA.pm\' in place...',
                        'Loaded Preload::WarningA again.',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::WarningB',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/WarningB.pm\' in place...',
                        'Loaded Preload::WarningB',
                        'Failed to reload \'lib/Preload/WarningB.pm\' in place...',
                        'Loaded Preload::WarningB again.',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::ExporterA',
                        'Loaded Preload::B',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/ExporterA.pm\' cannot be reloaded in place...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::B',
                        'Loaded Preload::ExporterB',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Changed file \'lib/Preload/ExporterB.pm\' cannot be reloaded in place...',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::B',
                        'Loaded Preload::IncChange',
                        'Runner detected a change in one or more preloaded modules...',
                        'Attempting to reload \'lib/Preload/IncChange.pm\' in place...',
                        'Failed to reload \'lib/Preload/IncChange.pm\' in place...',
                        'Reloading \'Preload/IncChange.pm\' loaded TEMP/Preload/IncChange.pm instead, @INC must have been altered at lib/Test2/Harness/Runner/Preloader.pm',
                        'blacklisting changed files and reloading stage...',
                        'Loaded Preload::A',
                        'Loaded Preload::B',
                    ],
                },
                "Reload happened as expected",
            );
        },
    );

    yath(command => 'stop', exit => 0);
};


done_testing;
