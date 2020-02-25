use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use App::Yath::Util qw/find_yath/;

yath(
    command => 'help',
    args    => [],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{^Usage: .*yath COMMAND \[options\]$}m, "Found usage statement");
        like($out->{output}, qr{^Available Commands:$}m, "available commands");

        # Sample some essential commands
        like($out->{output}, qr{^\s+help:  Show the list of commands$}m,         "'help' command is listed");
        like($out->{output}, qr{^\s+test:  Run tests$}m,                         "'test' command is listed");
        like($out->{output}, qr{^\s+start:  Start the persistent test runner$}m, "'start' command is listed");
    },
);

yath(
    command => 'help',
    args    => ['help'],
    exit    => 0,
    test    => sub {
        my $out    = shift;
        my $script = find_yath();

        is($out->{output}, <<"        EOT", "Got output for the help command");
help - Show the list of commands

This command provides a list of commands when called with no arguments.
When given a command name as an argument it will print the help for that
command.

Usage: $script help
        EOT
    },
);

yath(
    command => 'help',
    args    => ['test'],
    exit    => 0,
    test    => sub {
        my $out = shift;

        like($out->{output}, qr{^test - Run tests$}m,     "Found summary");
        like($out->{output}, qr{^\[YATH OPTIONS\]$}m,     "Found yath options");
        like($out->{output}, qr{^  Developer$}m,          "Found Developer category");
        like($out->{output}, qr{^  Help and Debugging$}m, "Found help category");
        like($out->{output}, qr{^  Plugins$}m,            "Found plugin category");
        like($out->{output}, qr{^\[COMMAND OPTIONS\]$}m,  "Found command options");
        like($out->{output}, qr{^  Display Options$}m,    "Found display category");
        like($out->{output}, qr{^  Formatter Options$}m,  "Found formatter category");
        like($out->{output}, qr{^  Logging Options$}m,    "Found logging category");
        like($out->{output}, qr{^  Run Options$}m,        "Found run category");
        like($out->{output}, qr{^  Runner Options$}m,     "Found runner category");
        like($out->{output}, qr{^  Workspace Options$}m,  "Found workspace category");
    },
);

done_testing;
