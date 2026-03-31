use Test2::V0 -target => 'App::Yath::Options::Tests';

my $parse = \&App::Yath::Options::Tests::parse_options;

subtest "all fields default to undef (null-by-default design)" => sub {
    my $tests = $parse->([], no_set_env => 1)->{settings}{tests};

    is($tests->{use_fork},          0,     "use_fork defaults to 0 (Bool type)");
    is($tests->{load},              undef, "load defaults to undef");
    is($tests->{use_timeout},       undef, "use_timeout defaults to undef");
    is($tests->{includes},          undef, "includes defaults to undef");
    is($tests->{env_vars},          undef, "env_vars defaults to undef");
    is($tests->{event_timeout},     undef, "event_timeout defaults to undef");
    is($tests->{post_exit_timeout}, undef, "post_exit_timeout defaults to undef");
    is($tests->{lib},               undef, "lib defaults to undef");
    is($tests->{blib},              undef, "blib defaults to undef");
    is($tests->{retry},             undef, "retry defaults to undef");
    is($tests->{cover},             undef, "cover defaults to undef");
};

subtest "includes PathList option via -I" => sub {
    my $tests = $parse->(['-I', '/my/lib', '-I', '/other/lib'], no_set_env => 1)->{settings}{tests};
    ok(grep { $_ eq '/my/lib'    } @{$tests->{includes}}, "-I /my/lib added to includes");
    ok(grep { $_ eq '/other/lib' } @{$tests->{includes}}, "-I /other/lib added to includes");
};

subtest "env_vars Map via -E" => sub {
    my $tests = $parse->(['-E', 'FOO=bar', '-E', 'BAZ=qux'], no_set_env => 1)->{settings}{tests};
    is($tests->{env_vars}{FOO}, 'bar', "-E FOO=bar sets env_vars{FOO}");
    is($tests->{env_vars}{BAZ}, 'qux', "-E BAZ=qux sets env_vars{BAZ}");
};

subtest "load List via -m" => sub {
    my $tests = $parse->(['-m', 'Storable', '-m', 'POSIX'], no_set_env => 1)->{settings}{tests};
    ok(grep { $_ eq 'Storable' } @{$tests->{load}}, "-m Storable adds to load");
    ok(grep { $_ eq 'POSIX'    } @{$tests->{load}}, "-m POSIX adds to load");
};

subtest "--lib Bool enables lib" => sub {
    my $tests = $parse->(['--lib'], no_set_env => 1)->{settings}{tests};
    is($tests->{lib}, 1, "--lib sets lib to 1");
};

subtest "--blib Bool enables blib" => sub {
    my $tests = $parse->(['--blib'], no_set_env => 1)->{settings}{tests};
    is($tests->{blib}, 1, "--blib sets blib to 1");
};

subtest "use_fork Bool option" => sub {
    my $tests = $parse->(['--fork'], no_set_env => 1)->{settings}{tests};
    is($tests->{use_fork}, 1, "--fork sets use_fork to 1");

    my $tests_off = $parse->(['--no-fork'], no_set_env => 1)->{settings}{tests};
    is($tests_off->{use_fork}, 0, "--no-fork sets use_fork to 0");
};

subtest "event_timeout Scalar option" => sub {
    my $tests = $parse->(['--event-timeout', '60'], no_set_env => 1)->{settings}{tests};
    is($tests->{event_timeout}, 60, "--event-timeout sets event_timeout");
};

subtest "retry Scalar option" => sub {
    my $tests = $parse->(['--retry', '2'], no_set_env => 1)->{settings}{tests};
    is($tests->{retry}, 2, "--retry sets retry to 2");
};

subtest "load_import defaults to undef" => sub {
    my $tests = $parse->([], no_set_env => 1)->{settings}{tests};
    is($tests->{load_import}, undef, "load_import defaults to undef");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{tests}, ['Getopt::Yath::Settings::Group'], "tests settings is a Settings::Group");
};

done_testing;
