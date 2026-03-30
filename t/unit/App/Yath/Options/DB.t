use Test2::V0 -target => 'App::Yath::Options::DB';

# parse_options is exported as a function into the module namespace, not a method
my $parse = \&App::Yath::Options::DB::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "default values when no env vars set" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_DB_CONFIG YATH_DB_DRIVER YATH_DB_NAME YATH_DB_USER YATH_DB_PASS YATH_DB_DSN YATH_DB_HOST YATH_DB_PORT YATH_DB_SOCKET USER/;

    my $db = $parse->([], no_set_env => 1)->{settings}{db};

    is($db->{config}, undef, "config defaults to undef");
    is($db->{driver}, undef, "driver defaults to undef");
    is($db->{name},   undef, "name defaults to undef");
    is($db->{user},   undef, "user defaults to undef when USER not set");
    is($db->{pass},   undef, "pass defaults to undef");
    is($db->{dsn},    undef, "dsn defaults to undef");
    is($db->{host},   undef, "host defaults to undef");
    is($db->{port},   undef, "port defaults to undef");
    is($db->{socket}, undef, "socket defaults to undef");
};

subtest "CLI options are parsed correctly" => sub {
    my $db = $parse->(
        ['--db-driver', 'PostgreSQL', '--db-name', 'mydb', '--db-user', 'alice',
         '--db-pass', 'secret', '--db-host', 'localhost', '--db-port', '5432'],
        no_set_env => 1,
    )->{settings}{db};

    is($db->{driver}, 'PostgreSQL', "driver is set from CLI");
    is($db->{name},   'mydb',       "name is set from CLI");
    is($db->{user},   'alice',      "user is set from CLI");
    is($db->{pass},   'secret',     "pass is set from CLI");
    is($db->{host},   'localhost',  "host is set from CLI");
    is($db->{port},   '5432',       "port is set from CLI");
};

subtest "dsn and socket options" => sub {
    my $db = $parse->(
        ['--db-dsn', 'dbi:Pg:dbname=foo', '--db-socket', '/tmp/pg.sock'],
        no_set_env => 1,
    )->{settings}{db};

    is($db->{dsn},    'dbi:Pg:dbname=foo', "dsn is set from CLI");
    is($db->{socket}, '/tmp/pg.sock',      "socket is set from CLI");
};

subtest "from_env_vars: YATH_DB_DRIVER" => sub {
    local $ENV{YATH_DB_DRIVER} = 'MySQL';
    my $db = $parse->([], no_set_env => 1)->{settings}{db};
    is($db->{driver}, 'MySQL', "YATH_DB_DRIVER populates driver");
};

subtest "from_env_vars: YATH_DB_NAME" => sub {
    local $ENV{YATH_DB_NAME} = 'envdb';
    my $db = $parse->([], no_set_env => 1)->{settings}{db};
    is($db->{name}, 'envdb', "YATH_DB_NAME populates name");
};

subtest "from_env_vars: USER fallback for user" => sub {
    local %ENV = %ENV;
    delete $ENV{YATH_DB_USER};
    local $ENV{USER} = 'bob';
    my $db = $parse->([], no_set_env => 1)->{settings}{db};
    is($db->{user}, 'bob', "USER env var populates user when YATH_DB_USER is not set");
};

subtest "from_env_vars: YATH_DB_USER takes precedence over USER" => sub {
    local $ENV{YATH_DB_USER} = 'dbuser';
    local $ENV{USER}         = 'sysuser';
    my $db = $parse->([], no_set_env => 1)->{settings}{db};
    is($db->{user}, 'dbuser', "YATH_DB_USER takes precedence over USER");
};

subtest "CLI option overrides env var" => sub {
    local $ENV{YATH_DB_DRIVER} = 'MySQL';
    my $db = $parse->(['--db-driver', 'SQLite'], no_set_env => 1)->{settings}{db};
    is($db->{driver}, 'SQLite', "CLI --db-driver overrides YATH_DB_DRIVER env var");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{db}, ['Getopt::Yath::Settings::Group'], "db settings is a Settings::Group");
};

done_testing;
