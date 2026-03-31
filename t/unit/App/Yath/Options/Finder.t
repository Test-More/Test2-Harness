use Test2::V0 -target => 'App::Yath::Options::Finder';

my $parse = \&App::Yath::Options::Finder::parse_options;

subtest "default values" => sub {
    my $finder = $parse->([], no_set_env => 1)->{settings}{finder};

    is($finder->{class},      'App::Yath::Finder', "class defaults to App::Yath::Finder");
    is($finder->{extensions}, [qw/t t2/],          "extensions default to [t, t2]");
    is($finder->{no_long},    0, "no_long defaults to 0");
    is($finder->{only_long},  0, "only_long defaults to 0");
};

subtest "class normalize: default is used as-is (no expansion needed)" => sub {
    # Default is already 'App::Yath::Finder' — no normalize triggered on default
    my $finder = $parse->([], no_set_env => 1)->{settings}{finder};
    is($finder->{class}, 'App::Yath::Finder', "default class is App::Yath::Finder");
};

subtest "extensions list: --ext strips leading dots" => sub {
    my $finder = $parse->(['--ext', '.pm', '--ext', 't'], no_set_env => 1)->{settings}{finder};
    # normalize strips leading dots
    is($finder->{extensions}, ['pm', 't'], "leading dots are stripped from extensions");
};

subtest "extensions can be provided with split_on comma" => sub {
    my $finder = $parse->(['--extensions', 't,t2'], no_set_env => 1)->{settings}{finder};
    is($finder->{extensions}, [qw/t t2/], "comma-separated extensions are split");
};

subtest "no_long Bool option" => sub {
    my $finder = $parse->(['--no-long'], no_set_env => 1)->{settings}{finder};
    is($finder->{no_long}, 1, "--no-long sets no_long to 1");
};

subtest "only_long Bool option" => sub {
    my $finder = $parse->(['--only-long'], no_set_env => 1)->{settings}{finder};
    is($finder->{only_long}, 1, "--only-long sets only_long to 1");
};

subtest "rerun_modes BoolMap default includes all => 1" => sub {
    my $finder = $parse->([], no_set_env => 1)->{settings}{finder};
    is($finder->{rerun_modes}{all}, 1, "rerun_modes defaults to {all => 1}");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{finder}, ['Getopt::Yath::Settings::Group'], "finder settings is a Settings::Group");
};

done_testing;
