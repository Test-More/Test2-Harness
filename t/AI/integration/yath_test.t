use Test2::V0;
use v5.38;

use File::Spec ();

# End-to-end: the `test` command scans files into jobs, queues them through a
# real harness service, and reports per-job results with an aggregate exit code.
#
# Run in a child process so the harness/collector get real STDOUT/STDERR file
# descriptors (an in-process in-memory capture has no real fd and breaks the
# collector's fd handling).

my @inc = map { File::Spec->rel2abs($_) } 'lib';

sub run_test_cmd (@args) {
    my $code = 'use App::Yath2; exit(App::Yath2->new(args => ["test", @ARGV])->run);';
    my @cmd  = ($^X, (map { "-I$_" } @inc), '-e', $code, @args);

    my $out = `@{[ join ' ', map { quote($_) } @cmd ]} 2>&1`;
    my $exit = $? >> 8;
    return ($exit, $out);
}

sub quote ($s) {
    return $s unless $s =~ /[^\w.\/-]/;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

subtest passing_file => sub {
    my ($exit, $out) = run_test_cmd('t/AI/scripts/collector_pass.pl');
    is($exit, 0, "a passing test yields exit 0") or diag($out);
    like($out, qr/collector_pass\.pl: PASS/, "reports PASS for the job");
};

subtest failing_file => sub {
    my ($exit, $out) = run_test_cmd('t/AI/scripts/collector_fail.pl');
    is($exit, 1, "a failing test yields exit 1") or diag($out);
    like($out, qr/collector_fail\.pl: FAIL/, "reports FAIL for the job");
};

subtest no_files => sub {
    my ($exit, $out) = run_test_cmd();
    is($exit, 1, "no files is a usage error (exit 1)");
    like($out, qr/Usage: yath test/, "prints command usage");
};

done_testing;
