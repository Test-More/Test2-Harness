use Test2::V0 -target => 'App::Yath::Command::test';

subtest 'metadata' => sub {
    is(CLASS->name,    'test',  'name');
    is(CLASS->group,   ' main', 'group');
    ok(CLASS->summary,          'summary is non-empty');
    ok(CLASS->description,      'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   1, 'accepts_dot_args is 1');
    is(CLASS->args_include_tests, 1, 'args_include_tests is 1');
    is(CLASS->load_plugins,       1, 'load_plugins is 1');
    is(CLASS->load_resources,     1, 'load_resources is 1');
    is(CLASS->load_renderers,     1, 'load_renderers is 1');
};

subtest 'daemon-related flags' => sub {
    is(CLASS->start_daemon_runner, 0, 'start_daemon_runner is 0');
    is(CLASS->check_argv,          1, 'check_argv returns 1');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'),       'is a App::Yath::Command');
    ok(CLASS->isa('App::Yath::Command::start'), 'is a App::Yath::Command::start');
    ok(CLASS->isa('App::Yath::Command::run'),   'is a App::Yath::Command::run');
};

done_testing;
