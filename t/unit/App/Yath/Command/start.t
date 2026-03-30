use Test2::V0 -target => 'App::Yath::Command::start';

subtest 'metadata' => sub {
    is(CLASS->name,    'start',  'name');
    is(CLASS->group,   'daemon', 'group');
    ok(CLASS->summary,           'summary is non-empty');
    ok(CLASS->description,       'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   1, 'accepts_dot_args is 1');
    is(CLASS->args_include_tests, 0, 'args_include_tests is 0');
    is(CLASS->load_plugins,       1, 'load_plugins is 1');
    is(CLASS->load_resources,     1, 'load_resources is 1');
    is(CLASS->load_renderers,     1, 'load_renderers is 1');
};

subtest 'option_modules' => sub {
    my @mods = CLASS->option_modules;
    ok(scalar(@mods) > 0, 'option_modules returns a non-empty list');
    ok((grep { /^App::Yath::Options::/ } @mods) > 0, 'option_modules contains App::Yath::Options modules');
};

subtest 'process_collector_name' => sub {
    is(CLASS->process_collector_name, 'collector', 'process_collector_name is collector');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
