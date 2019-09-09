use Test2::V0 -target => 'App::Yath';
# HARNESS-DURATION-SHORT

use ok $CLASS;

subtest import => sub {
    package my::yath;

    my @args;
    my $control = main::mock $main::CLASS => (
        override => [
            do_exec     => sub { },
            run_command => sub { @args = @_ },
        ],
    );

    local $App::Yath::SCRIPT;

    my $ref;
#line 20 "my-yath"
    $main::CLASS->import(['help'], \$ref);
#line 22 "t/App/Yath.t"
    main::ref_ok($ref, 'CODE', "got a coderef");

    $ref->();

    main::is(
        \@args,
        [$main::CLASS, 'App::Yath::Command::help', 'help', main::hash(sub { main::etc() })],
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

subtest command_from_argv => sub {
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
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'test', "defaulted to test with no args");
    is(\@argv, [], "argv still empty");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ();
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'run', "defaulted to run with no args, but persisting runner");
    is(\@argv, [], "argv still empty");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 0;
    @argv = ('-v');
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'test', "defaulted to test with an option");
    is(\@argv, ['-v'], "argv not changed");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ('-v');
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'run', "defaulted to run with an option and persist");
    is(\@argv, ['-v'], "argv not changed");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 0;
    @argv = ('t');
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'test', "defaulted to test with a dir");
    is(\@argv, ['t'], "argv not changed");
    is(\@info, ["\n** Defaulting to the 'test' command **\n\n"], "Got printed info");

    @info = ();
    $persist = 1;
    @argv = ('t');
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'run', "defaulted to run a dir and persist");
    is(\@argv, ['t'], "argv not changed");
    is(\@info, ["\n** Persistent runner detected, defaulting to the 'run' command **\n\n"], "Got printed info");

    for my $arg ('h', '-h', '--h', 'help', '--help', '-help') {
        @info = ();
        $persist = 0;
        @argv = ($arg, 'x');
        $cmd = $CLASS->command_from_argv(\@argv);
        is($cmd, 'help', "'$arg' -> 'help'");
        is(\@argv, ['x'], "argv shifted");
        is(\@info, [], "No info");
    }

    for my $arg ('foo.jsonl', 'foo.jsonl.gz', 'foo.jsonl.bz2') {
        @info = ();
        $persist = 0;
        @argv = ($arg, 'x');
        $cmd = $CLASS->command_from_argv(\@argv);
        is($cmd, 'replay', "'$arg' means replay");
        is(\@argv, [$arg, 'x'], "argv not changed");
        is(\@info, ["\n** First argument is a log file, defaulting to the 'replay' command **\n\n"], "got info");
    }

    @info = ();
    $persist = 0;
    @argv = ('test', 'x');
    $cmd = $CLASS->command_from_argv(\@argv);
    is($cmd, 'test', "first arg is a command");
    is(\@argv, ['x'], "argv shifted");
    is(\@info, [], "No info");
};

subtest pre_parse_args => sub {
     my $pp_argv = $CLASS->pre_parse_args(
        [
            '-x',
            '--longer' => 'arg',
            qw/foo bar baz/,
            '-pFoo',
            '--plugin' => 'Bar',
            '-p=Baz',
            '-I=foo',
            '-I' => 'bar',
            '--include=baz',
            '--include' => 'bat',
            '--plugin=Bat',
            '--',
            '-p' => 'uhg',
            'bleh',
            'blotch',
            '::',
            'pear',
            'apple',
            'bananananan',
            '-xyz',
        ]
    );
    is($pp_argv->{opts}, ['-x', '--longer' => 'arg', qw/foo bar baz/, '-I=foo', '-I' => 'bar', '--include=baz', '--include' => 'bat'], "Got opts");
    is($pp_argv->{list}, ['-p', 'uhg', 'bleh', 'blotch'], "Got list");
    is($pp_argv->{pass}, ['pear', 'apple', 'bananananan', '-xyz'], "Got args to pass");
    is($pp_argv->{plugins}, [qw/Foo Bar Baz Bat/], "Got plugins");
    like($pp_argv->{inc}, [qw{foo bar baz bat}, qr{lib$}, qr{blib/lib$}, qr{blib/arch$}], "Got libs");

    $pp_argv = $CLASS->pre_parse_args(
        [
            '-x',
            '--longer' => 'arg',
            qw/foo bar baz/,
            '-pFoo',
            '--plugin' => 'Bar',
            '-p=Baz',
            '-I=foo',
            '-I' => 'bar',
            '--include=baz',
            '--include' => 'bat',
            '--no-lib',
            '--no-blib',
            '--tlib',
            '--no-plugins', # <---- this is what we are testing now
            '--plugin=Bat',
            '--',
            '-p' => 'uhg',
            'bleh',
            'blotch',
            '::',
            'pear',
            'apple',
            'bananananan',
            '-xyz',
        ]
    );
    is($pp_argv->{opts}, ['-x', '--longer' => 'arg', qw/foo bar baz/, '-I=foo', '-I' => 'bar', '--include=baz', '--include' => 'bat', '--no-lib', '--no-blib', '--tlib'], "Got opts");
    is($pp_argv->{list}, ['-p', 'uhg', 'bleh', 'blotch'], "Got list");
    is($pp_argv->{pass}, ['pear', 'apple', 'bananananan', '-xyz'], "Got args to pass");
    is($pp_argv->{plugins}, [qw/Bat/], "Got only 1 plugin");
    like($pp_argv->{inc}, [qw{foo bar baz bat}, qr{t/lib$}], "Got libs");

    $pp_argv = $CLASS->pre_parse_args(
        [
            '-x',
            '--longer' => 'arg',
            qw/foo bar baz/,
            '-pFoo',
            '--plugin' => 'Bar',
            '-p=Baz',
            '--plugin=Bat',
            '::',
            'pear',
            'apple',
            'bananananan',
            '-xyz',
        ]
    );
    is($pp_argv->{opts}, ['-x', '--longer' => 'arg', qw/foo bar baz/], "Got opts");
    is($pp_argv->{list}, [], "Got empty list");
    is($pp_argv->{pass}, ['pear', 'apple', 'bananananan', '-xyz'], "Got args to pass");
    is($pp_argv->{plugins}, [qw/Foo Bar Baz Bat/], "Got plugins");
};

done_testing;
