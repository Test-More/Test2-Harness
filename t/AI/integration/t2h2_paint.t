use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;

# t2h2_paint reads an events file and prints the painted subtest graph. Produce
# a real events file via the collector, then check the script's output.

my $script = 'scripts/t2h2_paint';

sub painted_lines (@args) {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    Test2::Harness2::Collector->start(
        name         => "paint", is_test => 1, run_uuid => "RUN",
        processor    => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-Ilib', 't/AI/scripts/paint_job.pl'],
    );

    my $out = qx{$^X -Ilib \Q$script\E @args \Q$ef\E};
    return [split /\n/, $out];
}

subtest script_present => sub {
    ok(-f $script, "t2h2_paint exists");
    ok(-x $script, "t2h2_paint is executable");
};

subtest paints_the_subtest_graph => sub {
    my $lines = painted_lines('--no-color');

    ok((grep { $_ eq '*  top pass' } @$lines),    "top-level passing assertion painted with '*'");
    ok((grep { $_ eq 'X  outer' } @$lines),        "failing subtest painted with 'X'");
    ok((grep { $_ eq ' \\' } @$lines),             "subtest branch marker present");
    ok((grep { $_ eq '  *  child ok' } @$lines),   "passing child indented two columns");
    ok((grep { $_ eq '  X  child fail' } @$lines), "failing child painted with 'X'");
    ok((grep { $_ eq '  ^' } @$lines),             "subtest terminator present");
};

subtest color_flag_emits_ansi => sub {
    my $lines = painted_lines('--color');
    ok((grep { /\e\[/ } @$lines), "--color emits ANSI escapes");
};

done_testing;
