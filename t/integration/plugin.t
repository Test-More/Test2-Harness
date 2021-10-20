use Test2::V0;

use App::Yath::Tester qw/yath/;
use File::Temp qw/tempdir/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

sub verify {
    my (@outputs) = @_;

    my $text = '';
    for my $out (@outputs) {
        $text .= $out->{output};
    }

    like($text, qr/TEST PLUGIN: Loaded Plugin/, "Yath loaded the plugin");
    like($text, qr/TEST PLUGIN: duration_data/, "duration_data() was called");

    like($text, qr/TEST PLUGIN: changed_files\(Test2::Harness::Settings\)/,               "changed_files() was called");
    like($text, qr/TEST PLUGIN: get_coverage_tests\(Test2::Harness::Settings, HASH\(5\)\)/, "get_coverage_tests() was called");

    like($text, qr/TEST PLUGIN: munge_files/,     "munge_files() was called");
    like($text, qr/TEST PLUGIN: munge_search/,    "munge_search() was called");
    like($text, qr/TEST PLUGIN: inject_run_data/, "inject_run_data() was called");
    like($text, qr/TEST PLUGIN: handle_event/,    "handle_event() was called");

    like($text, qr/TEST PLUGIN: claim_file .*test\.tx$/m,           "claim_file(test.tx) was called");
    like($text, qr/TEST PLUGIN: claim_file .*TestPlugin\.pm$/m,     "claim_file(TestPlugin.pm) was called");
    like($text, qr/TEST PLUGIN: setup Test2::Harness::Settings/,    "setup() was called with settings");
    like($text, qr/TEST PLUGIN: teardown Test2::Harness::Settings/, "teardown() was called with settings");

    like($text, qr/\(TESTPLUG\)\s+STDERR WRITE$/m, "Got the STDERR write from the shellcall");
    like($text, qr/\(TESTPLUG\)\s+STDOUT WRITE$/m, "Got the STDOUT write from the shellcall");

    like(
        $text,
        qr/TEST PLUGIN: finish asserts_seen => 10, final_data => HASH, pass => 1, settings => Test2::Harness::Settings, tests_seen => 5/,
        "finish() was called with necessary args"
    );

    is(@{[$text =~ m/TEST PLUGIN: setup/g]},    1, "Only ran setup once");
    is(@{[$text =~ m/TEST PLUGIN: teardown/g]}, 1, "Only ran teardown once");
    is(@{[$text =~ m/TEST PLUGIN: finish/g]},   1, "Only ran finish once");

    if (ok($text =~ m/^FIELDS:(.*)$/m, "Found fields")) {
        my $data = decode_json($1);
        is(
            $data,
            [{
                name => 'test_plugin', details => 'foo', raw => 'bar', data => 'baz',
            }],
            "Injected the run data"
        );
    }

    my %rank = (
        test => 1,
        c    => 2,
        b    => 3,
        a    => 4,
        d    => 5,
    );

    my %jobs = reverse($text =~ m{job\s+(\d+)\s+.*\W(\w+)\.tx}g);
    is(\%jobs, \%rank, "Ran jobs in specified order");
}

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '--no-plugins', '-pTestPlugin', '--changes-plugin', 'TestPlugin'],
    exit    => 0,
    test    => \&verify,
);

unless ($ENV{AUTOMATED_TESTING}) {
    subtest persist => sub {
        verify(
            yath(command => 'start', args => ['--no-plugins', '-pTestPlugin'], exit => 0),
            yath(command => 'run', args => ['--no-plugins', '-pTestPlugin', exit => 0, $dir, '--ext=tx', '-A']),
            yath(command => 'stop', args => ['--no-plugins', '-pTestPlugin'], exit => 0),
        );
    };
}

done_testing;
