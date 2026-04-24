use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic encode_json/;

use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/default_writer_format/;
use App::Yath2::Command::replay;

# Build a synthetic log directory with one passing and one failing
# run, pack it as a .yath archive, then drive the replay command
# and check its output + exit code.

my $tmp  = tempdir(CLEANUP => 1);
my $logs = "$tmp/logs";
make_path("$logs/runs/RP/tests");
make_path("$logs/runs/RF/tests");

for my $rid (qw/RP RF/) {
    my $pass = $rid eq 'RP' ? 1 : 0;
    my $art  = {
        "runs/$rid/run.json"          => 'Test2::Harness2::Collector::Logger::JSON',
        "runs/$rid/tests/J.jsonl"     => 'Test2::Harness2::Collector::Logger::JSONL',
    };
    write_json_file_atomic("$logs/runs/$rid/artifacts.json", $art);
    write_json_file_atomic(
        "$logs/runs/$rid/run.json",
        {
            run_id  => $rid, created_at => 1, pending => [], running => [],
            done    => ['J'],
            results => {
                J => {
                    queued_at => 1, started_at => 2, completed_at => 3,
                    pass => $pass, exit => $pass ? 0 : 256,
                    rel_file => 't/j.t', abs_file => '/abs/j.t', file => '/abs/j.t',
                },
            },
        },
    );
    open my $jf, '>', "$logs/runs/$rid/tests/J.jsonl" or die $!;
    print $jf encode_json({event_id => "$rid-EV", facet_data => {info => [{details => $rid}]}}), "\n";
    close $jf;
}

# Top-level artifacts manifest merging both runs.
write_json_file_atomic(
    "$logs/artifacts.json",
    {
        "runs/RP/run.json"        => 'Test2::Harness2::Collector::Logger::JSON',
        "runs/RP/tests/J.jsonl"   => 'Test2::Harness2::Collector::Logger::JSONL',
        "runs/RF/run.json"        => 'Test2::Harness2::Collector::Logger::JSON',
        "runs/RF/tests/J.jsonl"   => 'Test2::Harness2::Collector::Logger::JSONL',
    },
);

my $archive = "$tmp/run.yath";
App::Yath2::LogArchive->create(
    source => $logs,
    path   => $archive,
    format => default_writer_format(),
);
ok(-f $archive, 'archive created');

subtest 'replay directory, all runs -> exit 1 (one run failed)' => sub {
    my $cmd = App::Yath2::Command::replay->new(args => [$logs]);
    my $out = '';
    my $rc;
    {
        open(my $cap, '>', \$out) or die $!;
        my $orig = select $cap;
        $rc = $cmd->run;
        select $orig;
    }

    is($rc, 1, 'exit 1 because one replayed run failed');
    like($out, qr/"harness_run_end"/, 'at least one harness_run_end emitted');
    like($out, qr/"RP-EV"/,           'RP general event passed through');
    like($out, qr/"RF-EV"/,           'RF general event passed through');
};

subtest 'replay archive, filter to passing run -> exit 0' => sub {
    my $cmd = App::Yath2::Command::replay->new(args => [$archive, 'RP']);
    my $out = '';
    my $rc;
    {
        open(my $cap, '>', \$out) or die $!;
        my $orig = select $cap;
        $rc = $cmd->run;
        select $orig;
    }

    is($rc, 0, 'exit 0 when only the passing run is replayed');
    like($out,   qr/"RP-EV"/,   'RP event present');
    unlike($out, qr/"RF-EV"/,   'RF event NOT present (filtered out)');
};

subtest 'replay archive, filter to failing run -> exit 1' => sub {
    my $cmd = App::Yath2::Command::replay->new(args => [$archive, 'RF']);
    my $out = '';
    my $rc;
    {
        open(my $cap, '>', \$out) or die $!;
        my $orig = select $cap;
        $rc = $cmd->run;
        select $orig;
    }

    is($rc, 1, 'exit 1 when replayed run failed');
    like($out,   qr/"RF-EV"/, 'RF event present');
    unlike($out, qr/"RP-EV"/, 'RP event NOT present');
};

subtest 'missing log path is rejected' => sub {
    my $cmd = App::Yath2::Command::replay->new(args => ["$tmp/nope.yath"]);
    my $ok  = eval { $cmd->run; 1 };
    my $err = $@;
    ok(!$ok, 'died');
    like($err, qr/does not exist/, 'error mentions missing log');
};

done_testing;
