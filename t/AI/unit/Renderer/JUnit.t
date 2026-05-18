use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Cpanel::JSON::XS qw/encode_json/;
use App::Yath2::Log;
use App::Yath2::Renderer::Loop;
use App::Yath2::Renderer::JUnit;

# Default criticality = required.
{
    my $r = App::Yath2::Renderer::JUnit->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => {junit_out => '/tmp/x.xml'},
    );
    is($r->criticality, 'required', 'JUnit defaults to required criticality');
}

# Missing junit_out setting fails at start.
{
    my $r_bad = App::Yath2::Renderer::JUnit->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
    );
    like(dies { $r_bad->start }, qr/junit.*output|junit-out/i, 'start dies without junit output path');
}

# Empty junit_out also fails at start.
{
    my $r_empty = App::Yath2::Renderer::JUnit->new(
        log         => undef,
        parent_pid  => $$,
        command_pid => $$,
        out_fh      => \*STDOUT,
        settings    => {junit_out => ''},
    );
    like(dies { $r_empty->start }, qr/junit.*output|junit-out/i, 'start dies with empty junit output path');
}

# Build fixture: one pass + one fail job under run 1.
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/runs/1/jobs/1/0", "$dir/runs/1/jobs/2/0");

# Job 1 — passing assertion.
{
    open my $fh, '>', "$dir/runs/1/jobs/1/0/events.jsonl" or die "open j1 events: $!";
    print $fh encode_json({facet_data => {assert => {pass => 1, details => 'one'}}}) . "\n";
    close $fh;

    open my $sfh, '>', "$dir/runs/1/jobs/1/0/.sealed" or die "open j1 sealed: $!";
    print $sfh encode_json({sealed_at => 100, final_state => 'completed', pass => 1});
    close $sfh;
}

# Job 2 — failing assertion with a detail string that must appear in <failure>.
{
    open my $fh, '>', "$dir/runs/1/jobs/2/0/events.jsonl" or die "open j2 events: $!";
    print $fh encode_json({facet_data => {assert => {pass => 0, details => 'expected two'}}}) . "\n";
    close $fh;

    open my $sfh, '>', "$dir/runs/1/jobs/2/0/.sealed" or die "open j2 sealed: $!";
    print $sfh encode_json({sealed_at => 200, final_state => 'completed', pass => 0});
    close $sfh;
}

# Run 1 — sealed, failed.
{
    open my $sfh, '>', "$dir/runs/1/.sealed" or die "open run sealed: $!";
    print $sfh encode_json({sealed_at => 300, final_state => 'completed', pass => 0, exit => 1});
    close $sfh;
}

my $log      = App::Yath2::Log->new(dir => $dir);
my $out_path = "$dir/junit.xml";

my $renderer = App::Yath2::Renderer::JUnit->new(
    log         => $log,
    parent_pid  => $$,
    command_pid => $$,
    out_fh      => \*STDOUT,
    settings    => {junit_out => $out_path},
);

App::Yath2::Renderer::Loop::run($renderer);

ok(-e $out_path, 'XML file written');

my $xml = do {
    open my $fh, '<', $out_path or die "open $out_path: $!";
    local $/;
    <$fh>;
};

like($xml, qr/<\?xml/,                               'XML declaration present');
like($xml, qr/<testsuites/,                          'root testsuites element present');
like($xml, qr/<testsuite[^>]+name="run_1"/,          'run_1 testsuite present');
like($xml, qr/<testcase[^>]+name="job_1_try_0"/,     'testcase for job 1 present');
like($xml, qr/<testcase[^>]+name="job_2_try_0"/,     'testcase for job 2 present');
like($xml, qr{<failure>.*expected two.*</failure>}s, 'failure body includes assertion detail');
like($xml, qr/tests="2"/,                            'tests count is 2');
like($xml, qr/failures="1"/,                         'failures count is 1');
like($xml, qr/errors="0"/,                           'errors count is 0');

# Passing job should have no <failure> or <error> child.
# Extract just the job_1_try_0 testcase block and check it has no <failure>.
my ($tc1) = ($xml =~ m{(<testcase\b[^>]*name="job_1_try_0"[^>]*>.*?</testcase>)}s);
ok(defined $tc1, 'testcase for job_1_try_0 found');
unlike($tc1, qr/<failure/, 'passing job has no failure element');
unlike($tc1, qr/<error/,   'passing job has no error element');

done_testing;
