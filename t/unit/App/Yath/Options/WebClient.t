use Test2::V0 -target => 'App::Yath::Options::WebClient';

my $parse = \&App::Yath::Options::WebClient::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(defined &{CLASS() . '::parse_options'}, "parse_options() function is defined");
};

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_URL YATH_API_KEY/;

    my $wc = $parse->([], no_set_env => 1)->{settings}{webclient};

    is($wc->{url},     undef, "url defaults to undef");
    is($wc->{api_key}, undef, "api_key defaults to undef");
    is($wc->{grace},   0,     "grace defaults to 0");
};

subtest "url can be set via CLI" => sub {
    my $wc = $parse->(['--url', 'http://yath.example.com/'], no_set_env => 1)->{settings}{webclient};
    is($wc->{url}, 'http://yath.example.com/', "--url sets url");
};

subtest "--uri is an alias for --url" => sub {
    my $wc = $parse->(['--uri', 'http://yath.example.com/'], no_set_env => 1)->{settings}{webclient};
    is($wc->{url}, 'http://yath.example.com/', "--uri alias sets url");
};

subtest "api_key can be set via CLI" => sub {
    my $wc = $parse->(['--api-key', 'mykey123'], no_set_env => 1)->{settings}{webclient};
    is($wc->{api_key}, 'mykey123', "--api-key sets api_key");
};

subtest "grace Bool flag" => sub {
    my $wc = $parse->(['--grace'], no_set_env => 1)->{settings}{webclient};
    is($wc->{grace}, 1, "--grace sets grace to 1");
};

subtest "from_env_vars: YATH_URL populates url" => sub {
    local $ENV{YATH_URL} = 'http://from-env.example.com/';
    my $wc = $parse->([], no_set_env => 1)->{settings}{webclient};
    is($wc->{url}, 'http://from-env.example.com/', "YATH_URL env var populates url");
};

subtest "from_env_vars: YATH_API_KEY populates api_key" => sub {
    local $ENV{YATH_API_KEY} = 'env-api-key';
    my $wc = $parse->([], no_set_env => 1)->{settings}{webclient};
    is($wc->{api_key}, 'env-api-key', "YATH_API_KEY env var populates api_key");
};

subtest "CLI url overrides YATH_URL env var" => sub {
    local $ENV{YATH_URL} = 'http://from-env.example.com/';
    my $wc = $parse->(['--url', 'http://cli.example.com/'], no_set_env => 1)->{settings}{webclient};
    is($wc->{url}, 'http://cli.example.com/', "CLI --url overrides YATH_URL env var");
};

subtest "request_retry Count: explicit value is set" => sub {
    my $wc = $parse->(['--request-retry=3'], no_set_env => 1)->{settings}{webclient};
    is($wc->{request_retry}, 3, "--request-retry=3 sets count to 3");
};

subtest "request_retry Count: clear resets to 0" => sub {
    my $wc = $parse->(['--no-request-retry'], no_set_env => 1)->{settings}{webclient};
    is($wc->{request_retry}, 0, "--no-request-retry resets count to 0");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{webclient}, ['Getopt::Yath::Settings::Group'], "webclient settings is a Settings::Group");
};

done_testing;
