use Test2::V0 -target => 'App::Yath::Command::client::publish';

subtest 'metadata' => sub {
    is(CLASS->name, 'client-publish', 'name');
    my $group = CLASS->group;
    ok(ref($group) eq 'ARRAY', 'group is an arrayref (multiple groups)');
    ok((grep { $_ eq 'web client' } @$group),  'group includes web client');
    ok((grep { $_ eq 'log parsing' } @$group), 'group includes log parsing');
    ok(CLASS->summary,                          'summary is non-empty');
    ok(CLASS->description,                      'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   0, 'accepts_dot_args is 0');
    is(CLASS->args_include_tests, 0, 'args_include_tests is 0');
    is(CLASS->load_plugins,       0, 'load_plugins is 0');
    is(CLASS->load_resources,     0, 'load_resources is 0');
    is(CLASS->load_renderers,     0, 'load_renderers is 0');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
