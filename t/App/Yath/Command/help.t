use Test2::V0 -target => 'App::Yath::Command::help';
# HARNESS-DURATION-SHORT
require App::Yath;

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
  for my $cmd (sort $CLASS->command_list) {

    # Run 'yath cmd --help'
    my $stdout_1 = capture {
      my $cmd_class = App::Yath->load_command($cmd);
      undef $@;
      ok(lives { $cmd_class->new(args => { opts => ['--help'] }) },
         "does $cmd --help live");
      diag("exception: $@") if $@;
    };

    # Run 'yath help cmd'
    my $stdout_2 = capture {
        my $one = $CLASS->new;
        my $res;
        ok(lives { $res = $one->command_help($cmd) }, "ran $cmd\->command_help");
        is($res, 0, "got return of 0");
      };

    # Check the complete output of the 'test' command
    if ($cmd eq "test") {
      is($stdout_1, App::Yath::Command::test->usage, "printed usage of 'test --help'");
      is($stdout_2, App::Yath::Command::test->usage, "printed usage of 'help test'");
    }

    # Check the first line of the output of every command
    for my $t ( ["$cmd --help", $stdout_1 ],
                ["help $cmd",   $stdout_2 ]) {
      my ($what, $output) = @$t;
      my $first_line = _first_line($output);
      like($first_line, qr#\AUsage: t/App/Yath/Command/help\.t $cmd \[options\]#, "First line of usage message of '$what'");
    }
  }
};

sub _first_line {
  my ($text) = @_;
  my ($first) = ($text =~ /\A \n* (.*) \n/x);
  return $first;
}

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
        like(shift @lines, qr{help:  Show this list of commands}, "Help command is first");

        my (@command, @space);
        for my $line (@lines) {
            push @space => $line and next unless $line;
            push @command => $line;
        }

        ok(@space >= 4, "at least 4 sections");

        like(
            \@command,
            bag {
                item qr{projects:  Run tests for multiple projects};
                item qr{replay:  Replay a test run from an event log};
                item qr{test:  Run tests};
                item qr{init:  Create/update test.pl to run tests via Test2::Harness};
                item qr{reload:  Reload the persistent test runner};
                item qr{run:  Run tests using the persistent test runner};
                item qr{start:  Start the persistent test runner};
                item qr{stop:  Stop the persistent test runner};
                item qr{watch:  Monitor the persistent test runner};
                item qr{which:  Locate the persistent test runner};
                item qr{times:  Get times from a test log};
                etc;
            },
            "Got all basic commands (and maybe some extras)",
        );
    };

};

done_testing;
