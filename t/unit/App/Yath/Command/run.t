use Test2::V0 -target => 'App::Yath::Command::run';

subtest 'metadata' => sub {
    is(CLASS->name,    'run',    'name');
    is(CLASS->group,   'daemon', 'group');
    ok(CLASS->summary,           'summary is non-empty');
    ok(CLASS->description,       'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   1, 'accepts_dot_args is 1');
    is(CLASS->args_include_tests, 1, 'args_include_tests is 1');
    is(CLASS->load_plugins,       1, 'load_plugins is 1');
    is(CLASS->load_resources,     0, 'load_resources is 0');
    is(CLASS->load_renderers,     1, 'load_renderers is 1');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
