use Test2::V0;
# HARNESS-DURATION-LONG

use App::Yath::Tester qw/yath/;
use File::Temp qw/tempdir/;
use Test2::Harness::Util::File::JSONL;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });


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

    like($text, qr/TEST PLUGIN: changed_files\(Getopt::Yath::Settings\)/,               "changed_files() was called");
    like($text, qr/TEST PLUGIN: get_coverage_tests\(Getopt::Yath::Settings, HASH\(5\)\)/, "get_coverage_tests() was called");

    like($text, qr/TEST PLUGIN: munge_files/,     "munge_files() was called");
    like($text, qr/TEST PLUGIN: munge_search/,    "munge_search() was called");

    like($text, qr/TEST PLUGIN: claim_file .*test\.tx$/m,           "claim_file(test.tx) was called");
    like($text, qr/TEST PLUGIN: claim_file .*TestPlugin\.pm$/m,     "claim_file(TestPlugin.pm) was called");

    like($text, qr/Plugin \S+ implementes inject_run_data\(\) which is no longer used, the module needs to be updated/, "inject_run_data() deprecated");
    like($text, qr/Plugin \S+ implementes handle_event\(\) which is no longer used, the module needs to be updated/,    "handle_event() deprecated");
    like($text, qr/Plugin \S+ implementes setup\(\) which is no longer used, the module needs to be updated/,           "setup() deprecated");
    like($text, qr/Plugin \S+ implementes teardown\(\) which is no longer used, the module needs to be updated/,        "teardown() deprecated");

    my %jobs = reverse($text =~ m{LAUNCH.*job\s+(\d+)\s+.*\W(\w+)\.tx}g);
    is($jobs{test}, 1, "'test' ran first because it is long");
    is($jobs{a}, 5, "'a' ran last because it is short");
}

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-A', '--durations-threshold' => 1, '--no-plugins', '-pTestPlugin', '--changes-plugin', 'TestPlugin', '-v'],
    exit    => 0,
    test    => \&verify,
);

unless ($ENV{AUTOMATED_TESTING} || $ENV{AUTHOR_TESTING}) {
    subtest persist => sub {
        verify(
            yath(command => 'start', exit => 0, args => ['--no-plugins', '-pTestPlugin'], exit => 0),
            yath(command => 'run',   exit => 0, args => ['--no-plugins', '-pTestPlugin', '--changes-plugin', 'TestPlugin', exit => 0, $dir, '--ext=tx', '-A', '-v']),
            yath(command => 'stop',  exit => 0, args => ['--no-plugins', '-pTestPlugin'], exit => 0),
        );
    };
}

done_testing;
