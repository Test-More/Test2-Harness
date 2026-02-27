use Test2::V0 -target => 'App::Yath::Command';

subtest 'name() derives from package name' => sub {
    is(CLASS->name, 'App::Yath::Command', 'base class returns full package name when no prefix match');

    {
        package App::Yath::Command::testcmd;
        use parent 'App::Yath::Command';
    }
    is(App::Yath::Command::testcmd->name, 'testcmd', 'single-level subclass returns short name');

    {
        package App::Yath::Command::foo::bar;
        use parent 'App::Yath::Command';
    }
    is(App::Yath::Command::foo::bar->name, 'foo-bar', 'nested namespace uses hyphen separator');

    my $obj = CLASS->new();
    is($obj->name, 'App::Yath::Command', 'name() works on instance');
};

subtest 'group()' => sub {
    is(CLASS->group, 'Z-FIXME', 'base class returns Z-FIXME when no prefix');

    {
        package App::Yath::Command::sub::cmd;
        use parent 'App::Yath::Command';
    }
    is(App::Yath::Command::sub::cmd->group, undef, 'subcommand (contains hyphen in name) returns undef');
};

subtest 'default metadata' => sub {
    is(CLASS->summary,     'No Summary',     'default summary');
    is(CLASS->description, 'No Description', 'default description');
};

subtest 'boolean flags default to 0' => sub {
    is(CLASS->accepts_dot_args,   0, 'accepts_dot_args defaults to 0');
    is(CLASS->args_include_tests, 0, 'args_include_tests defaults to 0');
    is(CLASS->internal_only,      0, 'internal_only defaults to 0');
    is(CLASS->load_plugins,       0, 'load_plugins defaults to 0');
    is(CLASS->load_resources,     0, 'load_resources defaults to 0');
    is(CLASS->load_renderers,     0, 'load_renderers defaults to 0');
};

subtest 'cli_args and cli_dot return undef by default' => sub {
    is(CLASS->cli_args, undef, 'cli_args returns undef');
    is(CLASS->cli_dot,  undef, 'cli_dot returns undef');
};

subtest 'run() warns and returns 1' => sub {
    my $obj = CLASS->new();
    my $warned = 0;
    local $SIG{__WARN__} = sub { $warned++ };
    my $ret = $obj->run();
    is($ret,    1, 'run() returns 1');
    is($warned, 1, 'run() emits a warning');
};

subtest 'set_dot_args() croaks' => sub {
    my $obj = CLASS->new();
    like(
        dies { $obj->set_dot_args() },
        qr/set_dot_args is not implemented/,
        'set_dot_args croaks with expected message',
    );
};

subtest 'constructor attributes' => sub {
    my $obj = CLASS->new(
        settings     => { foo => 1 },
        args         => [qw/a b/],
        env_vars     => { PATH => '/usr/bin' },
        option_state => {},
        plugins      => [],
    );
    is($obj->settings,     { foo => 1 },   'settings set via constructor');
    is($obj->args,         [qw/a b/],      'args set via constructor');
    is($obj->env_vars,     { PATH => '/usr/bin' }, 'env_vars set via constructor');
    is($obj->option_state, {},             'option_state set via constructor');
    is($obj->plugins,      [],             'plugins set via constructor');
};

done_testing;
