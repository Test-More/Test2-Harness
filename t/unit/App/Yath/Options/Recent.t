use Test2::V0 -target => 'App::Yath::Options::Recent';

my $parse = \&App::Yath::Options::Recent::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(defined &{CLASS() . '::parse_options'}, "parse_options() function is defined");
};

subtest "default value for max is 10" => sub {
    my $recent = $parse->([], no_set_env => 1)->{settings}{recent};
    is($recent->{max}, 10, "max defaults to 10");
};

subtest "max can be set via CLI" => sub {
    my $recent = $parse->(['--recent-max', '25'], no_set_env => 1)->{settings}{recent};
    is($recent->{max}, 25, "max is set to 25 from CLI");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{recent}, ['Getopt::Yath::Settings::Group'], "recent settings is a Settings::Group");
};

done_testing;
