use Test2::V0 -target => 'App::Yath::Options::Runner';

my $parse = \&App::Yath::Options::Runner::parse_options;

subtest "includes Tests options (tests group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{tests}, "tests group is present (included from Tests)");
};

subtest "default values" => sub {
    my $runner = $parse->([], no_set_env => 1)->{settings}{runner};

    is($runner->{preload_retry_delay}, 5,     "preload_retry_delay defaults to 5");
    is($runner->{dump_depmap},         0,     "dump_depmap defaults to 0");
    is($runner->{reload_in_place},     0,     "reload_in_place defaults to 0");
    is(ref($runner->{preloads}),       'ARRAY', "preloads is an arrayref");
};

subtest "class defaults to Test2::Harness::Runner with no preloads" => sub {
    my $runner = $parse->([], no_set_env => 1)->{settings}{runner};
    is($runner->{class}, 'Test2::Harness::Runner', "class defaults to Test2::Harness::Runner");
};

subtest "class switches to Preloading when preloads are specified" => sub {
    my $runner = $parse->(['-P', 'Storable'], no_set_env => 1)->{settings}{runner};
    is($runner->{class}, 'Test2::Harness::Runner::Preloading',
       "class is Runner::Preloading when preloads are given");
};

subtest "preloads List option" => sub {
    my $runner = $parse->(
        ['--preload', 'Storable', '--preload', 'POSIX'],
        no_set_env => 1,
    )->{settings}{runner};
    ok(grep { $_ eq 'Storable' } @{$runner->{preloads}}, "Storable is in preloads");
    ok(grep { $_ eq 'POSIX'    } @{$runner->{preloads}}, "POSIX is in preloads");
};

subtest "preload_retry_delay can be set via CLI" => sub {
    my $runner = $parse->(['--preload-retry-delay', '10'], no_set_env => 1)->{settings}{runner};
    is($runner->{preload_retry_delay}, 10, "--preload-retry-delay sets delay");
};

subtest "dump_depmap Bool flag" => sub {
    my $runner = $parse->(['--dump-depmap'], no_set_env => 1)->{settings}{runner};
    is($runner->{dump_depmap}, 1, "--dump-depmap sets flag to 1");
};

subtest "reload_in_place Bool flag" => sub {
    my $runner = $parse->(['--reload'], no_set_env => 1)->{settings}{runner};
    is($runner->{reload_in_place}, 1, "--reload sets reload_in_place to 1");
};

subtest "class normalize: + prefix strips to fq name" => sub {
    my $runner = $parse->(['--runner', '+Test2::Harness::Runner'], no_set_env => 1)->{settings}{runner};
    is($runner->{class}, 'Test2::Harness::Runner', "'+ prefix strips to fq name'");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{runner}, ['Getopt::Yath::Settings::Group'], "runner settings is a Settings::Group");
};

done_testing;
