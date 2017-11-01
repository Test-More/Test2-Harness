use Test2::V0 -target => 'App::Yath::Command::help';

use ok $CLASS;

sub capture(&) {
    my $code = shift;

    my $stdout = "";
    local *STDOUT;
    open(STDOUT, '>', \$stdout) or die "Could not open new STDOUT: $!";

    $code->();

    return $stdout;
}

subtest command_help => sub {
    my $stdout = capture {
        my $one = $CLASS->new;
        is($one->command_help('test'), 0, "got return of 0");
    };
    is($stdout, App::Yath::Command::test->usage, "printed usage of command");
};

subtest run => sub {
    subtest a_command => sub {
        my $stdout = capture {
            my $one = $CLASS->new(args => {opts => ['test'], list => []});
            is($one->run(), 0, "got return of 0");
        };
        is($stdout, App::Yath::Command::test->usage, "printed usage of command");
    };

    subtest command_list => sub {
        my $stdout = capture {
            my $one = $CLASS->new(args => {opts => [], list => []});
            is($one->run(), 0, "got return of 0");
        };

        my @lines = split /\n/, $stdout;

        my $skip_space   = sub { shift @lines while @lines && $lines[0] eq '' };
        my $skip_section = sub { shift @lines while @lines && $lines[0] ne '' };

        $skip_space->();
        is(shift @lines, 'Usage: t/App/Yath/Command/help.t COMMAND [options]', "Got usage line");

        $skip_space->();
        is(shift @lines, 'Available Commands:', "got title of available commands");

        $skip_space->();
        is(shift @lines, '      help:  Show a this list of commands', "Help command is first");

        my (@command, @space);
        for my $line (@lines) {
            push @space => $line and next unless $line;
            push @command => $line;
        }

        ok(@space >= 4, "at least 4 sections");

        is(
            \@command,
            bag {
                item '    replay:  Replay a test run from an event log';
                item '      test:  Run tests';
                item '      init:  Create/update test.pl to run tests via Test2::Harness';
                item '    reload:  Reload the persistent test runner';
                item '       run:  Run tests using the persistent test runner';
                item '     start:  Start the persistent test runner';
                item '      stop:  Stop the persistent test runner';
                item '     watch:  Monitor the persistent test runner';
                item '     which:  Locate the persistent test runner';
                item '     times:  Get times from a test log';
                etc;
            },
            "Got all basic commands (and maybe soem extras)"
        );
    };

};

done_testing;
