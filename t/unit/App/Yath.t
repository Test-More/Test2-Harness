use Test2::V0 -target => 'App::Yath';

use App::Yath;

use Test2::Harness::Util qw/clean_path/;

subtest init => sub {
    my $one = $CLASS->new(argv => [foo => 'bar']);
    isa_ok($one, $CLASS);

    isa_ok($one->settings, 'App::Yath::Settings');

    is($one->settings->yath->script, clean_path(__FILE__), "Yath script set to this test file");

    is($one->_argv, [foo => 'bar'], "Grabbed argv");

    is($one->config, {}, "Default empty config");

    my $two = App::Yath->new();
    is($two->_argv, [], "default to empty argv");
};

{
    require App::Yath::Command;
    $INC{'App/Yath/Command/NOGEN.pm'} = __FILE__;
    $INC{'App/Yath/Command/GEN.pm'} = __FILE__;

    package App::Yath::Command::NOGEN;
    use App::Yath::Options;

    option 'verbose' => (
        type   => 'c',
        prefix => 'foo',
        short  => 'v',
        post_process => sub { $main::POST++ },
    );

    use Test2::Harness::Util::HashBase qw/settings argv/;
    our @ISA = ('App::Yath::Command');

    sub run { 123 }

    package App::Yath::Command::GEN;

    our @ISA = ('App::Yath::Command::NOGEN');

    sub generate_run_sub { ('ran gen_run_sub', @_) }
}

subtest generate_run_sub => sub {
    my $one = $CLASS->new(argv => ['GEN']);

    my @out = $one->generate_run_sub('main::RUNSUB');
    is(
        \@out,
        [
            'ran gen_run_sub',
            'App::Yath::Command::GEN',
            'main::RUNSUB',
            [],
        ],
        "Ran command generate_run_sub with correct args"
    );

    my $two = $CLASS->new(argv => ['NOGEN', '-vv']);

    $two->generate_run_sub('main::RUNSUB');
    is($two->settings->foo->verbose, 2, "Set verbose with CLI args");
    ok(defined(&main::RUNSUB), "Added the runsub to the provided symbol");
    is(main::RUNSUB(), 123, "runsub does what we expect (runs the command run method) and we get the exit value");
    is($main::POST, 1, "Ran post-process callbacks");
};

subtest run_command => sub {
    my $one = $CLASS->new();

    my $cmd = mock {run => undef, name => 'acmd'};

    is(
        dies { $one->run_command($cmd) },
        "Command 'acmd' did not return an exit value.\n",
        "Command must return an exit value"
    );

    $cmd->{run} = 12;

    is($one->run_command($cmd), 12, "Returned the proper exit code");
};

subtest command_class => sub {
    my $one = $CLASS->new(argv => ['GEN']);
    is($one->command_class, 'App::Yath::Command::GEN', "Got command class from args");

    $one->{_command_class} = 'foo';

    is($one->command_class, "foo", "A cache is used");
};

subtest load_command => sub {
    my $one = $CLASS->new();

    is($one->load_command('GEN'), 'App::Yath::Command::GEN', "Works for valid command (inline)");
    is($one->load_command('test'), 'App::Yath::Command::test', "Works for valid command (real)");

    is($one->load_command('gsdfgsdfgsd', check_only => 1), undef, "Missing module is ok in 'check_only' mode");

    is(
        dies { $one->load_command('dgfsdfgsdf') },
        "yath command 'dgfsdfgsdf' not found. (did you forget to install App::Yath::Command::dgfsdfgsdf?)\n",
        "Correct message for missing command"
    );

    is(
        dies {
            local @INC = (sub { die "module failed\n" });
            $one->load_command('jgjgjfdfk');
        },
        "module failed\n",
        "If a module load throws an exception we pass it along"
    );
};

subtest load_options => sub {
    local @INC = (@INC, 't/lib');
    my $one = $CLASS->new();

    $one->settings->yath->no_scan_plugins = 1;

    my $options = $one->load_options();
    is(
        $options->included,
        {
            'App::Yath::Options::Debug'      => 1,
            'App::Yath::Options::PreCommand' => 1,
        },
        "Included Debug and PreCommand, but not plugins"
    );

    my $two = $CLASS->new();

    $two->settings->yath->no_scan_plugins = 0;

    $options = $two->load_options();
    like(
        $options->included,
        {
            'App::Yath::Options::Debug'      => 1,
            'App::Yath::Options::PreCommand' => 1,
            'App::Yath::Plugin::Options'     => 1,
        },
        "Included Debug and PreCommand, as well as the plugin"
    );

    ref_is($options, $two->load_options, "Cached options result");
};

subtest process_argv => sub {
    local @INC = (@INC, 't/lib');

    my $one = $CLASS->new(
        argv   => [qw/-Dfoo -Dbar --pre-hook fake -x -y --post-hook blah uhg/],
        config => {fake => [qw/-Dbaz -z/], other => [qw/-noop/]},
    );

    warns { is($one->process_argv(), $one->_argv, "remaining args are returned") };

    is($one->command_class, 'App::Yath::Command::fake', "Set command class");
    is(
        ${$one->settings->fake},
        {
            post_hook => 1,
            pre_hook  => 1,
            x         => 1,
            y         => 1,
            z         => 1,
        },
        "Added 'fake' command settings"
    );

    like(
        $one->settings->yath->dev_libs,
        bag {
            item qr/foo$/;
            item qr/bar$/;
            item qr/baz$/;
        },
        "Added the dev libs"
    );

    is($one->_argv, [qw/blah uhg/], "Remaining args");

    is($main::POST_HOOK, F(), "Did not run hook yet (requires command instance)");
    is($main::PRE_HOOK,  F(), "Did not run hook yet (requires command instance)");
};

subtest command_from_argv => sub {
    my $one = $CLASS->new();
    like(
        warning { is($one->_command_from_argv, 'test', "Default to test") },
        qr/Defaulting to the 'test' command/,
        "Warning about default"
    );

    my $control = mock $CLASS => ( override => [ find_pfile => sub { 1 } ] );
    like(
        warning { is($one->_command_from_argv, 'run', "Default to run if we have a persistence file") },
        qr/Persistent runner detected, defaulting to the 'run' command/,
        "Warning about default"
    );
    $control = undef;

    $one = $CLASS->new(argv => ['-f', '--foo', 'test', '-b', '--bar']);
    is($one->_command_from_argv(), "test", "Found 'test' command");
    is($one->_argv, ['-f', '--foo', '-b', '--bar'], "Command was removed from argv");

    $one = $CLASS->new(argv => ['-f', '--foo', 'hfajhdajshfj', '-b', '--bar']);
    is($one->_command_from_argv(), "hfajhdajshfj", "Found 'hfajhdajshfj' command");
    is($one->_argv, ['-f', '--foo', '-b', '--bar'], "Command was removed from argv");

    $one = $CLASS->new(argv => ['-f', '--foo', '--help', '-b', '--bar']);
    is($one->_command_from_argv(), "help", "Found 'help' command");
    is($one->_argv, ['-f', '--foo', '-b', '--bar'], "Command was removed from argv");

    $one = $CLASS->new(argv => ['-f', '--foo', '-h', '-b', '--bar']);
    is($one->_command_from_argv(), "help", "Found 'help' command");
    is($one->_argv, ['-f', '--foo', '-b', '--bar'], "Command was removed from argv");

    $one = $CLASS->new(argv => ['-f', '--foo', 'foo.jsonl.bz2', '-b', '--bar']);
    warns { is($one->_command_from_argv(), "replay", "Found 'replay' command because we got a log") };
    is($one->_argv, ['-f', '--foo', 'foo.jsonl.bz2', '-b', '--bar'], "log was not removed from argv");

    $one = $CLASS->new(argv => ['-f', '--foo', __FILE__, '-b', '--bar']);
    warns { is($one->_command_from_argv(), "test", "Found 'test' command because we got a path") };
    is($one->_argv, ['-f', '--foo', __FILE__, '-b', '--bar'], "path was not removed");
};

done_testing;
