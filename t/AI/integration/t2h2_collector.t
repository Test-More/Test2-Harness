use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# The t2h2_collector script runs a single test file under the collector,
# filling in the output filenames, the TAP parser, the auditor processor, and
# the test recorder. It exits 0 when the test passed and 1 when it failed.

my $script = 'scripts/t2h2_collector';

sub run_script ($test_file, $dir) {
    my @cmd = ($^X, '-Ilib', $script, $test_file, $dir);
    system(@cmd);
    return $? >> 8;
}

sub final_state ($dir) {
    my $path = "$dir/state.jsonl.zst";
    return undef unless -e $path;
    my $r = open_zstd_reader($path);
    my $line = $r->readline // return undef;
    return decode_json($line)->{facet_data}{harness_final_state};
}

subtest script_present => sub {
    ok(-f $script, "t2h2_collector script exists");
    ok(-x $script, "t2h2_collector script is executable");
};

subtest passing_test => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $code = run_script('t/AI/scripts/collector_pass.pl', $dir);

    is($code, 0, "script exits 0 for a passing test");

    ok(-e "$dir/events.jsonl.zst", "events file produced");
    ok(-e "$dir/state.jsonl.zst",  "state file produced");
    ok(!-e "$dir/transitions.jsonl.zst", "no transitions file (transitions go to pipes)");

    my $fs = final_state($dir);
    is($fs->{pass}, 1, "state file records a pass");
};

subtest failing_test => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $code = run_script('t/AI/scripts/collector_fail.pl', $dir);

    is($code, 1, "script exits 1 for a failing test");

    my $fs = final_state($dir);
    is($fs->{pass}, 0, "state file records a fail");
    ok($fs->{fail_count} >= 1, "fail_count is at least one");
};

subtest usage_error => sub {
    system($^X, '-Ilib', $script);
    isnt($? >> 8, 0, "missing arguments is an error");
};

done_testing;
