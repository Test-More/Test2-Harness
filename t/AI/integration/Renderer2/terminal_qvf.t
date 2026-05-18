use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;
use App::Yath2::Renderer2::Loop;
use App::Yath2::Renderer2::Terminal;
use App::Yath2::Renderer2::TerminalAuto;
use App::Yath2::Formatter::Txt;

# ---------------------------------------------------------------------------
# Build a sealed two-job fixture:  job 1 = pass, job 2 = fail.
# All .sealed markers are written manually (no running collector).
# ---------------------------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/runs/1/jobs/1/0", "$dir/runs/1/jobs/2/0");

# Job 1 — pass: one passing assertion + plan.
{
    open my $fh, '>', "$dir/runs/1/jobs/1/0/events.jsonl" or die "open j1 events: $!";
    print $fh encode_json({facet_data => {assert => {pass  => 1, details => 'ok 1 - one'}}}) . "\n";
    print $fh encode_json({facet_data => {plan   => {count => 1}}}) . "\n";
    close $fh;

    open my $rfh, '>', "$dir/runs/1/jobs/1/0/report.jsonl" or die "open j1 report: $!";
    print $rfh encode_json({pass => 1}) . "\n";
    close $rfh;

    open my $sfh, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open j1 sealed: $!";
    print $sfh encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sfh;
}

# Job 2 — fail: one failing assertion with trace + one info line.
{
    open my $fh, '>', "$dir/runs/1/jobs/2/0/events.jsonl" or die "open j2 events: $!";
    print $fh encode_json({
        facet_data => {
            assert => {pass  => 0, details => 'expected ok 2'},
            trace  => {frame => ['main', '/path/to/t.t', 42]},
        },
    }) . "\n";
    print $fh encode_json({facet_data => {info => [{details => 'context line'}]}}) . "\n";
    close $fh;

    open my $rfh, '>', "$dir/runs/1/jobs/2/0/report.jsonl" or die "open j2 report: $!";
    print $rfh encode_json({pass => 0}) . "\n";
    close $rfh;

    open my $sfh, '>', "$dir/runs/1/jobs/2/0/.sealed" or die "open j2 sealed: $!";
    print $sfh encode_json({sealed_at => 200, final_state => 'completed', pass => 0});
    close $sfh;
}

# Run seal — failed, exit=1.
{
    open my $sfh, '>', "$dir/runs/1/.sealed" or die "open run sealed: $!";
    print $sfh encode_json({sealed_at => 300, final_state => 'completed', pass => 0, exit => 1});
    close $sfh;
}

# ---------------------------------------------------------------------------
# TerminalAuto: an in-memory scalar handle is not a TTY → Txt formatter.
# ---------------------------------------------------------------------------
my $captured = '';
open my $out, '>', \$captured or die "open scalar fh: $!";

my $formatter = App::Yath2::Renderer2::TerminalAuto::pick(out_fh => $out);
isa_ok($formatter, ['App::Yath2::Formatter::Txt'], 'non-TTY out_fh selects Txt formatter');

# ---------------------------------------------------------------------------
# Drive the full pipeline: Log → Loop → Terminal → captured scalar.
# ---------------------------------------------------------------------------
my $log = App::Yath2::Log->new(dir => $dir);

my $renderer = App::Yath2::Renderer2::Terminal->new(
    log         => $log,
    parent_pid  => $$,
    command_pid => $$,
    out_fh      => $out,
    settings    => {
        verbose   => 0,
        formatter => $formatter,
    },
);

App::Yath2::Renderer2::Loop::run($renderer);
close $out;

# ---------------------------------------------------------------------------
# Assertions — QVF policy + formatter output + no ANSI escapes.
# ---------------------------------------------------------------------------

# Pass job: one-line PASS summary, no event details.
like($captured, qr/PASS:.*\bjob\b.*\b1\b/, 'pass job has PASS summary line');
unlike($captured, qr/ok 1 - one/, 'pass job events not dumped in QVF mode');

# Fail job: FAIL header + event details via Txt formatter.
like($captured, qr/FAIL:.*\bjob\b.*\b2\b/, 'fail job has FAIL header line');
like($captured, qr/expected ok 2/,         'fail job assert details rendered by formatter');
like($captured, qr/context line/,          'fail job info line rendered by formatter');

# Run sealed summary.
like($captured, qr/HARNESS:.*run\b.*\bFAILED\b/, 'run sealed summary shows FAILED');
like($captured, qr/exit=1/,                      'run sealed summary carries exit code');

# No ANSI escape sequences (Txt formatter, non-TTY path).
unlike($captured, qr/\e\[/, 'no ANSI escape sequences in Txt formatter output');

done_testing;
