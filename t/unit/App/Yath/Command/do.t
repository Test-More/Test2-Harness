use Test2::V0 -target => 'App::Yath::Command::do';

subtest 'metadata' => sub {
    is(CLASS->name,    'do',    'name');
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

subtest 'cli_args' => sub {
    is(CLASS->cli_args, '[run or test args]', 'cli_args');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'),      'is a App::Yath::Command');
    ok(CLASS->isa('App::Yath::Command::test'), 'is a App::Yath::Command::test');
};

done_testing;
