use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use App::Yath::Util qw/find_yath/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

yath(
    command => 'help',
    args    => [],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{^Usage: .*yath}m, "Found usage statement");

        # Sample some essential commands
        like($out->{output}, qr{help.+Show the list of commands}m,         "'help' command is listed");
        like($out->{output}, qr{test.+Run tests}m,                         "'test' command is listed");
        like($out->{output}, qr{start.+Start a test runner}m, "'start' command is listed");
    },
);

yath(
    command => 'help',
    args    => ['help'],
    exit    => 0,
    test    => sub {
        my $out    = shift;
        my $script = find_yath();

        like($out->{output}, qr/Command selected: help/, "Showing help for the help command");
    },
);

yath(
    command => 'help',
    args    => ['test'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{Command selected: test \(App::Yath::Command::test\)}, "Show command");

        like($out->{output}, qr{Yath Options\s+\(yath\)},           "Yath Options");
        like($out->{output}, qr{Harness Options\s+\(harness\)},     "Harness Options");
        like($out->{output}, qr{Finder Options\s+\(finder\)},       "Finder Options");
        like($out->{output}, qr{IPC Options\s+\(ipc\)},             "IPC Options");
        like($out->{output}, qr{Renderer Options\s+\(renderer\)},   "Renderer Options");
        like($out->{output}, qr{Resource Options\s+\(resource\)},   "Resource Options");
        like($out->{output}, qr{Run Options\s+\(run\)},             "Run Options");
        like($out->{output}, qr{Runner Options\s+\(runner\)},       "Runner Options");
        like($out->{output}, qr{Scheduler Options\s+\(scheduler\)}, "Scheduler Options");
        like($out->{output}, qr{Terminal Options\s+\(term\)},       "Terminal Options");
        like($out->{output}, qr{Test Options\s+\(tests\)},          "Test Options");
    },
);

done_testing;
