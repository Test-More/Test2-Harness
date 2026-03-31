use Test2::V0 -target => 'App::Yath::Options::Publish';

my $parse = \&App::Yath::Options::Publish::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(defined &{CLASS() . '::parse_options'}, "parse_options() function is defined");
};

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{USER};

    my $pub = $parse->([], no_set_env => 1)->{settings}{publish};

    is($pub->{mode},           'qvfd', "mode defaults to 'qvfd'");
    is($pub->{buffer_size},    100,    "buffer_size defaults to 100");
    is($pub->{flush_interval}, undef,  "flush_interval defaults to undef");
    is($pub->{force},          0,      "force defaults to 0");
};

subtest "mode can be set via CLI" => sub {
    my $pub = $parse->(['--publish-mode', 'complete'], no_set_env => 1)->{settings}{publish};
    is($pub->{mode}, 'complete', "mode is set from CLI");
};

subtest "buffer_size can be set via CLI" => sub {
    my $pub = $parse->(['--publish-buffer-size', '200'], no_set_env => 1)->{settings}{publish};
    is($pub->{buffer_size}, 200, "buffer_size is set from CLI");
};

subtest "flush_interval can be set via CLI" => sub {
    my $pub = $parse->(['--publish-flush-interval', '2'], no_set_env => 1)->{settings}{publish};
    is($pub->{flush_interval}, 2, "flush_interval is set from CLI");
};

subtest "force Bool flag" => sub {
    my $pub = $parse->(['--publish-force'], no_set_env => 1)->{settings}{publish};
    is($pub->{force}, 1, "--publish-force sets force to 1");

    my $pub2 = $parse->(['--no-publish-force'], no_set_env => 1)->{settings}{publish};
    is($pub2->{force}, 0, "--no-publish-force sets force to 0");
};

subtest "retry Count type increments" => sub {
    # Count with no explicit value starts at autofill (0) and bumps to 1
    my $pub_default = $parse->([], no_set_env => 1)->{settings}{publish};
    ok(defined $pub_default->{retry}, "retry is defined");

    # Clear resets to 0
    my $pub_clear = $parse->(['--no-publish-retry'], no_set_env => 1)->{settings}{publish};
    is($pub_clear->{retry}, 0, "--no-publish-retry resets count to 0");

    # Explicit value is set directly
    my $pub_set = $parse->(['--publish-retry=5'], no_set_env => 1)->{settings}{publish};
    is($pub_set->{retry}, 5, "--publish-retry=5 sets count to 5");
};

subtest "user defaults to \$ENV{USER}" => sub {
    local $ENV{USER} = 'testuser';
    my $pub = $parse->([], no_set_env => 1)->{settings}{publish};
    is($pub->{user}, 'testuser', "user defaults to \$ENV{USER}");
};

subtest "user can be overridden via CLI" => sub {
    local $ENV{USER} = 'sysuser';
    my $pub = $parse->(['--publish-user', 'deployer'], no_set_env => 1)->{settings}{publish};
    is($pub->{user}, 'deployer', "CLI --publish-user overrides \$ENV{USER}");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{publish}, ['Getopt::Yath::Settings::Group'], "publish settings is a Settings::Group");
};

done_testing;
