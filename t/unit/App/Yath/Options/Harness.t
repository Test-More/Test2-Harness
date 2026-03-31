use Test2::V0 -target => 'App::Yath::Options::Harness';

my $parse = \&App::Yath::Options::Harness::parse_options;

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{T2_HARNESS_DUMMY};

    my $harness = $parse->([], no_set_env => 1)->{settings}{harness};
    is($harness->{dummy},           0,      "dummy defaults to 0");
    is($harness->{procname_prefix}, 'yath', "procname_prefix defaults to 'yath'");
};

subtest "dummy flag can be set" => sub {
    my $harness = $parse->(['-d'], no_set_env => 1)->{settings}{harness};
    is($harness->{dummy}, 1, "-d sets dummy to 1");
};

subtest "dummy flag from env var" => sub {
    local $ENV{T2_HARNESS_DUMMY} = 1;
    my $harness = $parse->([], no_set_env => 1)->{settings}{harness};
    is($harness->{dummy}, 1, "T2_HARNESS_DUMMY env var sets dummy");
};

subtest "procname_prefix trigger appends -yath when absent" => sub {
    my $harness = $parse->(['--procname-prefix', 'myapp'], no_set_env => 1)->{settings}{harness};
    is($harness->{procname_prefix}, 'myapp-yath', "'-yath' is appended to prefix that lacks it");
};

subtest "procname_prefix trigger does not duplicate -yath" => sub {
    my $harness = $parse->(['--procname-prefix', 'myyath'], no_set_env => 1)->{settings}{harness};
    like($harness->{procname_prefix}, qr/yath/, "prefix containing 'yath' is not double-suffixed");
};

subtest "procname_prefix trigger with 'yath' boundary" => sub {
    my $harness = $parse->(['--procname-prefix', 'ci-yath-runner'], no_set_env => 1)->{settings}{harness};
    is($harness->{procname_prefix}, 'ci-yath-runner', "prefix with 'yath' between dashes is unchanged");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{harness}, ['Getopt::Yath::Settings::Group'], "harness settings is a Settings::Group");
};

done_testing;
