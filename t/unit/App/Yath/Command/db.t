use Test2::V0;

BEGIN {
    eval { require App::Yath::Command::db };
    if ($@) {
        my ($missing) = $@ =~ m{Can't locate (\S+\.pm)};
        $missing //= 'a required module';
        $missing =~ s{/}{::}g; $missing =~ s{\.pm$}{};
        skip_all("App::Yath::Command::db requires $missing");
    }
}

my $CLASS = 'App::Yath::Command::db';

subtest 'metadata' => sub {
    is($CLASS->name,    'db',       'name');
    is($CLASS->group,   'database', 'group');
    ok($CLASS->summary,             'summary is non-empty');
    ok($CLASS->description,         'description is non-empty');
};

subtest 'flags' => sub {
    is($CLASS->accepts_dot_args,   0, 'accepts_dot_args is 0');
    is($CLASS->args_include_tests, 0, 'args_include_tests is 0');
    is($CLASS->load_plugins,       0, 'load_plugins is 0');
    is($CLASS->load_resources,     0, 'load_resources is 0');
    is($CLASS->load_renderers,     0, 'load_renderers is 0');
};

subtest 'inheritance' => sub {
    ok($CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
