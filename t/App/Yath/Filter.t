package A::Test::Package;
use Test2::V0 -target => 'App::Yath::Filter';
use Test2::IPC;
use Test2::Require::RealFork;

use Test2::API qw/test2_stack/;
use File::Temp qw/tempfile/;

BEGIN {
    plan 8;

    # This filter is designed to work along with forking, so we test it with
    # forking.
    my $pid = fork();
    die "Could not fork" unless defined $pid;

    if ($pid) {
        # Let the child finish first.
        my $check = waitpid($pid, 0);
        my $exit = $?;

        is($check, $pid, "was able to wait on other process");
        ok(!$exit, "Other process exited fine");

        App::Yath::Filter->import(
            sub {
                is(caller, "main", "called from main package");
            }
        );
    }
    else {
        my ($fh, $filename) = tempfile(CLEANUP => 1);
        print $fh <<"        EOT";
use Test2::V0;

is(__LINE__, 3, "line numbers are correct");
is(__FILE__, "$filename", "Got filename");
is(__PACKAGE__, "main", "in main package");

is([caller(0)], [], "no caller");

is(
    [<DATA>],
    ["foo\\n", "bar\\n", "baz\\n"],
    "Got data section"
);

# Edge cases suck :-(
\__DATA__
foo
bar
baz
        EOT
        close($fh);
        App::Yath::Filter->import($filename);
    }
}

die "Should not get here!\n";

__DATA__

Should not see this data!
