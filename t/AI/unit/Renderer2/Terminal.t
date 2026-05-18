use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;
use App::Yath2::Renderer2::Loop;
use App::Yath2::Renderer2::Terminal;
use App::Yath2::Formatter::Txt;

# -----------------------------------------------------------------------
# Build a sealed fixture with 1 passing job + 1 failing job.
# -----------------------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/runs/1/jobs/1/0", "$dir/runs/1/jobs/2/0");

# Job 1 — pass: one passing assertion, report pass=1.
{
    open my $fh, '>', "$dir/runs/1/jobs/1/0/events.jsonl" or die "open j1 events: $!";
    print $fh encode_json({facet_data => {assert => {pass => 1, details => 'one'}}}) . "\n";
    close $fh;

    open my $rfh, '>', "$dir/runs/1/jobs/1/0/report.jsonl" or die "open j1 report: $!";
    print $rfh encode_json({pass => 1}) . "\n";
    close $rfh;

    open my $sfh, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open j1 sealed: $!";
    print $sfh encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sfh;
}

# Job 2 — fail: one failing assertion + one info line.
{
    open my $fh, '>', "$dir/runs/1/jobs/2/0/events.jsonl" or die "open j2 events: $!";
    print $fh encode_json({facet_data => {assert => {pass => 0, details => 'two'}}}) . "\n";
    print $fh encode_json({facet_data => {info   => [{details => 'context', tag => 'DIAG'}]}}) . "\n";
    close $fh;

    open my $rfh, '>', "$dir/runs/1/jobs/2/0/report.jsonl" or die "open j2 report: $!";
    print $rfh encode_json({pass => 0}) . "\n";
    close $rfh;

    open my $sfh, '>', "$dir/runs/1/jobs/2/0/.sealed" or die "open j2 sealed: $!";
    print $sfh encode_json({sealed_at => 200, final_state => 'completed', pass => 0});
    close $sfh;
}

# Run — sealed, failed.
{
    open my $sfh, '>', "$dir/runs/1/.sealed" or die "open run sealed: $!";
    print $sfh encode_json({sealed_at => 300, final_state => 'completed', pass => 0, exit => 1});
    close $sfh;
}

# -----------------------------------------------------------------------
# QVF mode (verbose=0) — the default / primary test.
# -----------------------------------------------------------------------
subtest qvf_mode => sub {
    my $log = App::Yath2::Log->new(dir => $dir);

    my $captured = '';
    open my $out, '>', \$captured or die "open scalar fh: $!";

    my $renderer = App::Yath2::Renderer2::Terminal->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => $out,
        settings    => {
            verbose   => 0,
            formatter => App::Yath2::Formatter::Txt->new,
        },
    );

    App::Yath2::Renderer2::Loop::run($renderer);
    close $out;

    # Job 1 (pass): single PASS summary line, no event details.
    like $captured,   qr/PASS:.*\bjob\b.*\b1\b/, 'job 1 pass line present';
    unlike $captured, qr/\bone\b/,               'no event details for passing job';

    # Job 2 (fail): FAIL header + event dump via formatter.
    like $captured, qr/FAIL:.*\bjob\b.*\b2\b/, 'job 2 fail line present';
    like $captured, qr/\btwo\b/,               'fail assertion detail present';
    like $captured, qr/\bcontext\b/,           'fail diag/info line present';

    # Run summary.
    like $captured, qr/HARNESS:.*run\b.*\bFAILED\b/, 'run summary shows FAILED';
    like $captured, qr/exit=1/,                      'run summary shows exit code';
};

# -----------------------------------------------------------------------
# verbose=1 — job-start lines should appear, failure dump still present.
# -----------------------------------------------------------------------
subtest verbose_mode => sub {
    my $log = App::Yath2::Log->new(dir => $dir);

    my $captured = '';
    open my $out, '>', \$captured or die "open scalar fh: $!";

    my $renderer = App::Yath2::Renderer2::Terminal->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => $out,
        settings    => {
            verbose   => 1,
            formatter => App::Yath2::Formatter::Txt->new,
        },
    );

    App::Yath2::Renderer2::Loop::run($renderer);
    close $out;

    # Both jobs should have a "started" line.
    my $started_count = () = $captured =~ /HARNESS:.*started/g;
    is $started_count, 2, 'two job-start lines for verbose=1';

    # Failure details still present.
    like $captured, qr/\btwo\b/,     'fail assertion detail present in verbose mode';
    like $captured, qr/\bcontext\b/, 'fail diag present in verbose mode';
};

# -----------------------------------------------------------------------
# Formatter required: missing formatter in settings must croak.
# -----------------------------------------------------------------------
subtest formatter_required => sub {
    my $log = App::Yath2::Log->new(dir => $dir);

    my $renderer = App::Yath2::Renderer2::Terminal->new(
        log         => $log,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => {verbose => 0},    # no formatter key
    );

    like(
        dies { $renderer->_formatter },
        qr/formatter is required/,
        '_formatter croaks when settings.formatter is absent',
    );
};

done_testing;
