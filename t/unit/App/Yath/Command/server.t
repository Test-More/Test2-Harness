use Test2::V0;

BEGIN {
    eval { require App::Yath::Command::server };
    if ($@) {
        my ($missing) = $@ =~ m{Can't locate (\S+\.pm)};
        $missing //= 'a required module';
        $missing =~ s{/}{::}g; $missing =~ s{\.pm$}{};
        skip_all("App::Yath::Command::server requires $missing");
    }
}

my $CLASS = 'App::Yath::Command::server';

subtest 'metadata' => sub {
    is($CLASS->name,    'server', 'name');
    is($CLASS->group,   'server', 'group');
    ok($CLASS->summary,           'summary is non-empty');
    ok($CLASS->description,       'description is non-empty');
};

subtest 'flags' => sub {
    is($CLASS->accepts_dot_args,   1, 'accepts_dot_args is 1');
    is($CLASS->args_include_tests, 0, 'args_include_tests is 0');
};

subtest 'cli_args' => sub {
    like($CLASS->cli_args, qr/log/, 'cli_args mentions log files');
};

subtest 'inheritance' => sub {
    ok($CLASS->isa('App::Yath::Command'), 'is a App::Yath::Command');
};

done_testing;
