use Test2::V0 -target => 'App::Yath';

use ok $CLASS;

subtest import => sub {
    package my::yath;

    local $App::Yath::SCRIPT;

    my $ref;
#line 12 "my-yath"
    $main::CLASS->import(['help'], \$ref);
#line 14 "t/App/Yath.t"
    main::ref_ok($ref, 'CODE', "got a coderef");

    my @args;
    my $control = main::mock(
        $main::CLASS,
        override => [
            run_command => sub { @args = @_ }
        ],
    );

    $ref->();

    main::is(
        \@args,
        [$main::CLASS, 'App::Yath::Command::help', 'help', []],
        "the ref calls run_command with the correct args"
    );

    main::is($App::Yath::SCRIPT, 'my-yath', 'set $App::Yath::SCRIPT');
    $main::CLASS->import(['help'], \$ref);
    main::is($App::Yath::SCRIPT, 'my-yath', '$App::Yath::SCRIPT not changed');
};

subtest load_command => sub {
    is($CLASS->load_command('help'), 'App::Yath::Command::help', "Loaded the help command");
    is(
        dies { $CLASS->load_command('a_fake_command') },
        "yath command 'a_fake_command' not found. (did you forget to install App::Yath::Command::a_fake_command?)\n",
        "Exception if the command is not valid"
    );

    local @INC = ('t/lib', @INC);
    like(
        dies { $CLASS->load_command('broken') },
        qr/This command is broken! at/,
        "Exception is propogated if command dies on compile"
    );
};

{
    package My::Command::a;

    our $RAN;
    our $OUT = 0;
    our $SHOW_BENCH;

    sub settings { {} }

    sub new {
        my $class = shift;
        bless {@_}, $class;
    }

    sub show_bench { $SHOW_BENCH }

    sub run { $RAN = shift; $OUT }
}

subtest run_command => sub {
    my $out = $CLASS->run_command('My::Command::a', 'a', [foo => 1]);
    is($out, 0, "got an exit value");
    is(
        $My::Command::a::RAN,
        {args => [foo => 1]},
        "It ran",
    );

    $My::Command::a::OUT = 1;
    $out = $CLASS->run_command('My::Command::a', 'a', [foo => 1]);
    is($out, 1, "got an exit value");

    is(
        dies { local $My::Command::a::OUT; $CLASS->run_command('My::Command::a', 'a', [foo => 1]) },
        "Command 'a' did not return an exit value.\n",
        "Commands must return an exit value"
    );

    require Test2::Util::Times;
    my $control1 = mock 'Test2::Util::Times' => (
        override => {
            render_bench => sub { "hi" },
        },
    );

    my @info;
    my $control2 = mock $CLASS => (
        override => {
            info => sub { shift; @info = @_ },
        },
    );

    $My::Command::a::SHOW_BENCH = 1;
    $CLASS->run_command('My::Command::a', 'a', [foo => 1]);

    is(\@info, ["hi", "\n\n"], "Showed bench data");
};

subtest parse_argv => sub {
    my @info;
    my $persist = 0;
    my $control2 = mock $CLASS => (
        override => {
            info => sub { shift; @info = @_ },
            find_pfile => sub { $persist },
        },
    );

    my (@argv, $cmd);

    @info = ();
    $persist = 0;
    @argv = ();
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'test', "defaulted to test with no args");
    is(\@argv, [], "argv still empty");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ();
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'run', "defaulted to run with no args, but persisting runner");
    is(\@argv, [], "argv still empty");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 0;
    @argv = ('-v');
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'test', "defaulted to test with an option");
    is(\@argv, ['-v'], "argv not changed");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ('-v');
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'run', "defaulted to run with an option and persist");
    is(\@argv, ['-v'], "argv not changed");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 0;
    @argv = ('t');
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'test', "defaulted to test with a dir");
    is(\@argv, ['t'], "argv not changed");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ('t');
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'run', "defaulted to run a dir and persist");
    is(\@argv, ['t'], "argv not changed");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    for my $arg ('h', '-h', '--h', 'help', '--help', '-help') {
        @info = ();
        $persist = 0;
        @argv = ($arg, 'x');
        $cmd = $CLASS->parse_argv(\@argv);
        is($cmd, 'help', "'$arg' -> 'help'");
        is(\@argv, ['x'], "argv shifted");
        is(\@info, [], "No info");
    }

    for my $arg ('foo.jsonl', 'foo.jsonl.gz', 'foo.jsonl.bz2') {
        @info = ();
        $persist = 0;
        @argv = ($arg, 'x');
        $cmd = $CLASS->parse_argv(\@argv);
        is($cmd, 'replay', "'$arg' means replay");
        is(\@argv, [$arg, 'x'], "argv not changed");
        is(\@info, ["\n** First argument is a log file, defaulting to the 'replay' command **\n\n"], "got info");
    }

    @info = ();
    $persist = 0;
    @argv = ('foo', 'x');
    $cmd = $CLASS->parse_argv(\@argv);
    is($cmd, 'foo', "first arg is a command");
    is(\@argv, ['x'], "argv shifted");
    is(\@info, [], "No info");
};

done_testing;
