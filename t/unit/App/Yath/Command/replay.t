use Test2::V0 -target => 'App::Yath::Command::replay';

subtest 'metadata' => sub {
    is(CLASS->name,    'replay',      'name');
    is(CLASS->group,   'log parsing', 'group');
    ok(CLASS->summary,                'summary is non-empty');
    ok(CLASS->description,            'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   1, 'accepts_dot_args is 1');
    is(CLASS->args_include_tests, 0, 'args_include_tests is 0');
    is(CLASS->load_plugins,       0, 'load_plugins is 0');
    is(CLASS->load_resources,     0, 'load_resources is 0');
    is(CLASS->load_renderers,     1, 'load_renderers is 1');
};

subtest 'cli_args' => sub {
    like(CLASS->cli_args, qr/event_log/, 'cli_args mentions event_log');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'),     'is a App::Yath::Command');
    ok(CLASS->isa('App::Yath::Command::run'), 'is a App::Yath::Command::run');
};

done_testing;
