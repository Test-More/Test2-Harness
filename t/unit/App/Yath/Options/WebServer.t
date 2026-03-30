use Test2::V0 -target => 'App::Yath::Options::WebServer';

my $parse = \&App::Yath::Options::WebServer::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "includes DB options" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{db}, "db group is present (included from DB)");
};

subtest "default values" => sub {
    my $ws = $parse->([], no_set_env => 1)->{settings}{webserver};

    is($ws->{host},       'localhost', "host defaults to 'localhost'");
    is($ws->{importers},  2,           "importers defaults to 2");
    is($ws->{launcher_args}, [],       "launcher_args defaults to empty arrayref");
};

subtest "port defaults to 8080 when no port_command set" => sub {
    my $ws = $parse->([], no_set_env => 1)->{settings}{webserver};
    is($ws->{port}, 8080, "port defaults to 8080");
};

subtest "host can be set via CLI" => sub {
    my $ws = $parse->(['--host', '0.0.0.0'], no_set_env => 1)->{settings}{webserver};
    is($ws->{host}, '0.0.0.0', "--host sets host");
};

subtest "port can be set via CLI" => sub {
    my $ws = $parse->(['--port', '9000'], no_set_env => 1)->{settings}{webserver};
    is($ws->{port}, '9000', "--port sets port");
};

subtest "importers can be set via CLI" => sub {
    my $ws = $parse->(['--importers', '4'], no_set_env => 1)->{settings}{webserver};
    is($ws->{importers}, 4, "--importers sets importers");
};

subtest "launcher can be set via CLI" => sub {
    my $ws = $parse->(['--launcher', 'Twiggy'], no_set_env => 1)->{settings}{webserver};
    is($ws->{launcher}, 'Twiggy', "--launcher sets launcher");
};

subtest "port_command can be set via CLI" => sub {
    my $ws = $parse->(['--port-command', 'echo 9001'], no_set_env => 1)->{settings}{webserver};
    is($ws->{port_command}, 'echo 9001', "--port-command sets port_command");
};

subtest "DB options are also parseable" => sub {
    my $settings = $parse->(['--db-driver', 'PostgreSQL'], no_set_env => 1)->{settings};
    is($settings->{db}{driver}, 'PostgreSQL', "DB --db-driver works via WebServer");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{webserver}, ['Getopt::Yath::Settings::Group'], "webserver settings is a Settings::Group");
};

done_testing;
