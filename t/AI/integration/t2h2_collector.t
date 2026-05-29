use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

# The t2h2_collector script spawns a collector for a single test file, loops
# over the notification messages the recorder sends over a unix transition
# socket, and prints a basic line for the start, each transition, and the final
# result. It writes the full event stream to the events file named as its
# second argument, and exits 0 when the test passed and 1 when it failed.

my $script = 'scripts/t2h2_collector';

# Returns ($exit_code, $stdout).
sub run_script ($test_file, $events_file) {
    my $out = qx{$^X -Ilib \Q$script\E \Q$test_file\E \Q$events_file\E};
    return ($? >> 8, $out);
}

subtest script_present => sub {
    ok(-f $script, "t2h2_collector script exists");
    ok(-x $script, "t2h2_collector script is executable");
};

subtest passing_test => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";
    my ($code, $out) = run_script('t/AI/scripts/collector_pass.pl', $ef);

    is($code, 0, "script exits 0 for a passing test");

    ok(-e $ef,                           "events file produced at the named path");
    ok(!-e "$dir/state.jsonl.zst",       "no state file");
    ok(!-e "$dir/transitions.jsonl.zst", "no transitions file");

    like($out, qr/^transition: starting$/m,  "printed the start transition");
    like($out, qr/^transition: completed$/m, "printed the completed transition");
    like($out, qr/^result: PASS$/m,          "printed a PASS result");
};

subtest failing_test => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($code, $out) = run_script('t/AI/scripts/collector_fail.pl', "$dir/events.jsonl.zst");

    is($code, 1, "script exits 1 for a failing test");
    like($out, qr/^result: FAIL$/m, "printed a FAIL result");
};

subtest verbose_pretty_print => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";
    my $out = qx{$^X -Ilib \Q$script\E -v t/AI/scripts/collector_pass.pl \Q$ef\E};

    is($? >> 8, 0, "-v run still exits 0");

    # The simple line is still there, now followed by a multi-line JSON dump.
    like($out, qr/^transition: starting$/m,    "simple line still printed under -v");
    like($out, qr/^\{\n\s+"facet_data"\s*:/m,  "pretty-printed (multi-line) JSON follows");
    like($out, qr/"harness_state_transition"/, "the JSON payload is dumped");
    like($out, qr/"uuid"/,                     "the dumped payload includes the collector uuid");
};

subtest usage_error => sub {
    system($^X, '-Ilib', $script);
    isnt($? >> 8, 0, "missing arguments is an error");
};

done_testing;
