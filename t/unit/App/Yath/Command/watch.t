use Test2::V0 -target => 'App::Yath::Command::watch';

subtest 'metadata' => sub {
    is(CLASS->name,    'watch',  'name');
    is(CLASS->group,   'daemon', 'group');
    ok(CLASS->summary,           'summary is non-empty');
    ok(CLASS->description,       'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   0, 'accepts_dot_args is 0');
    is(CLASS->args_include_tests, 0, 'args_include_tests is 0');
    is(CLASS->load_plugins,       0, 'load_plugins is 0');
    is(CLASS->load_resources,     0, 'load_resources is 0');
    is(CLASS->load_renderers,     1, 'load_renderers is 1');
};

subtest 'process_name' => sub {
    my $obj = CLASS->new();
    is($obj->process_name, 'watcher', 'process_name is watcher');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
