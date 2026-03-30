use Test2::V0 -target => 'App::Yath::Command::db::recent';

subtest 'metadata' => sub {
    is(CLASS->name, 'db-recent', 'name');
    my $group = CLASS->group;
    ok(ref($group) eq 'ARRAY', 'group is an arrayref (multiple groups)');
    ok((grep { $_ eq 'database' } @$group), 'group includes database');
    ok((grep { $_ eq 'history' } @$group),  'group includes history');
    ok(CLASS->summary,                       'summary is non-empty');
    ok(CLASS->description,                   'description is non-empty');
};

subtest 'flags' => sub {
    is(CLASS->accepts_dot_args,   0, 'accepts_dot_args is 0');
    is(CLASS->args_include_tests, 0, 'args_include_tests is 0');
};

subtest 'cli_args' => sub {
    is(CLASS->cli_args, '', 'cli_args is empty string');
};

subtest 'inheritance' => sub {
    ok(CLASS->isa('App::Yath::Command'),        'is a App::Yath::Command');
    ok(CLASS->isa('App::Yath::Command::recent'), 'is a App::Yath::Command::recent');
};

done_testing;
