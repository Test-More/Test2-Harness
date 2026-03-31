use Test2::V0 -target => 'App::Yath::Options::Yath';

my $parse = \&App::Yath::Options::Yath::parse_options;

subtest "includes Harness options (harness group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{harness}, "harness group is present (included from Harness)");
    ok(exists $settings->{yath},    "yath group is present");
};

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_USER USER/;

    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};

    is($yath->{version},   0,     "version defaults to 0 (Bool off)");
    is($yath->{show_opts}, undef, "show_opts defaults to undef");
    is($yath->{project},   undef, "project defaults to undef");
    is($yath->{user},      undef, "user defaults to undef when env vars not set");
};

subtest "user from YATH_USER env var" => sub {
    local $ENV{YATH_USER} = 'yathuser';
    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};
    is($yath->{user}, 'yathuser', "YATH_USER populates user");
};

subtest "user from USER env var as fallback" => sub {
    local %ENV = %ENV;
    delete $ENV{YATH_USER};
    local $ENV{USER} = 'sysuser';
    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};
    is($yath->{user}, 'sysuser', "USER env var populates user when YATH_USER not set");
};

subtest "YATH_USER takes precedence over USER" => sub {
    local $ENV{YATH_USER} = 'yathuser';
    local $ENV{USER}      = 'sysuser';
    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};
    is($yath->{user}, 'yathuser', "YATH_USER takes precedence over USER");
};

subtest "project can be set via CLI" => sub {
    my $yath = $parse->(['--project', 'myproject'], no_set_env => 1)->{settings}{yath};
    is($yath->{project}, 'myproject', "--project sets project");
};

subtest "--project-name is an alias for --project" => sub {
    my $yath = $parse->(['--project-name', 'altproject'], no_set_env => 1)->{settings}{yath};
    is($yath->{project}, 'altproject', "--project-name alias sets project");
};

subtest "version Bool flag -V" => sub {
    my $yath = $parse->(['-V'], no_set_env => 1)->{settings}{yath};
    is($yath->{version}, 1, "-V sets version to 1");
};

subtest "base_dir defaults to a non-empty string" => sub {
    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};
    ok(defined $yath->{base_dir} && length $yath->{base_dir},
       "base_dir is defined and non-empty (derived from cwd or VCS root)");
};

subtest "plugins List option defaults to empty list" => sub {
    my $yath = $parse->([], no_set_env => 1)->{settings}{yath};
    # plugins starts as undef before any plugins are specified
    ok(!defined($yath->{plugins}) || ref($yath->{plugins}) eq 'ARRAY',
       "plugins is undef or an arrayref by default");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{yath}, ['Getopt::Yath::Settings::Group'], "yath settings is a Settings::Group");
};

done_testing;
