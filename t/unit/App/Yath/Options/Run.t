use Test2::V0 -target => 'App::Yath::Options::Run';

my $parse = \&App::Yath::Options::Run::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "includes Tests options (tests group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{tests}, "tests group is present (included from Tests)");
};

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{AUTHOR_TESTING};

    my $run = $parse->([], no_set_env => 1)->{settings}{run};

    is($run->{abort_on_bail},  1, "abort_on_bail defaults to 1");
    is($run->{nytprof},        0, "nytprof defaults to 0");
    is($run->{interactive},    0, "interactive defaults to 0");
    is($run->{dbi_profiling},  0, "dbi_profiling defaults to 0");
    is($run->{author_testing}, 0, "author_testing defaults to 0");
    # run_id is auto-generated (UUID) when not specified
    like($run->{run_id}, qr/^[0-9A-Fa-f-]{36}$/, "run_id is auto-generated as a UUID");
};

subtest "abort_on_bail can be toggled" => sub {
    my $run_on  = $parse->(['--abort-on-bail'], no_set_env => 1)->{settings}{run};
    my $run_off = $parse->(['--no-abort-on-bail'], no_set_env => 1)->{settings}{run};
    is($run_on->{abort_on_bail},  1, "--abort-on-bail sets to 1");
    is($run_off->{abort_on_bail}, 0, "--no-abort-on-bail sets to 0");
};

subtest "run_id can be set via CLI" => sub {
    my $run = $parse->(['--run-id', 'myrun123'], no_set_env => 1)->{settings}{run};
    is($run->{run_id}, 'myrun123', "--run-id sets run_id");
};

subtest "nytprof Bool flag" => sub {
    my $run = $parse->(['--nytprof'], no_set_env => 1)->{settings}{run};
    is($run->{nytprof}, 1, "--nytprof sets nytprof to 1");
};

subtest "interactive Bool flag" => sub {
    my $run = $parse->(['--interactive'], no_set_env => 1)->{settings}{run};
    is($run->{interactive}, 1, "--interactive sets interactive to 1");
};

subtest "author_testing from env var" => sub {
    local $ENV{AUTHOR_TESTING} = '1';
    my $run = $parse->([], no_set_env => 1)->{settings}{run};
    is($run->{author_testing}, 1, "AUTHOR_TESTING env var sets author_testing");
};

subtest "author_testing trigger populates tests.env_vars" => sub {
    local %ENV = %ENV;
    delete $ENV{AUTHOR_TESTING};

    my $settings = $parse->(['-A'], no_set_env => 1)->{settings};
    is($settings->{run}{author_testing}, 1, "-A sets author_testing");
    is($settings->{tests}{env_vars}{AUTHOR_TESTING}, 1,
       "-A trigger sets AUTHOR_TESTING in tests.env_vars");
};

subtest "links List option" => sub {
    my $run = $parse->(['--link', 'https://ci.example.com/42', '--link', 'https://other.example.com/'], no_set_env => 1)->{settings}{run};
    is($run->{links}, ['https://ci.example.com/42', 'https://other.example.com/'],
       "--link appends to links list");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{run}, ['Getopt::Yath::Settings::Group'], "run settings is a Settings::Group");
};

done_testing;
