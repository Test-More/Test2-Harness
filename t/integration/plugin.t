use Test2::V0;

use App::Yath::Tester qw/yath_test_with_log yath_start yath_stop yath_run_with_log/;
use File::Temp qw/tempdir/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{};

my ($exit, $log, $out) = yath_test_with_log(undef, ['--no-plugins', '-pTestPlugin'], '-A');
ok(!$exit, "Exited success");

like($out, qr/TEST PLUGIN: Loaded Plugin/,   "Yath loaded the plugin");
like($out, qr/TEST PLUGIN: munge_files/,     "munge_files() was called");
like($out, qr/TEST PLUGIN: munge_search/,    "munge_search() was called");
like($out, qr/TEST PLUGIN: inject_run_data/, "inject_run_data() was called");
like($out, qr/TEST PLUGIN: handle_event/,    "handle_event() was called");

like($out, qr/TEST PLUGIN: claim_file .*test\.tx$/m,       "claim_file(test.tx) was called");
like($out, qr/TEST PLUGIN: claim_file .*TestPlugin\.pm$/m, "claim_file(TestPlugin.pm) was called");
like($out, qr/TEST PLUGIN: finish App::Yath::Settings/,    "finish() was called with settings");

if (ok($out =~ m/^FIELDS:(.*)$/m, "Found fields")) {
    my $data = decode_json($1);
    is(
        $data,
        [
            {
                name => 'test_plugin', details => 'foo', raw => 'bar', data => 'baz',
            }
        ],
        "Injected the run data"
    );
}

done_testing;
