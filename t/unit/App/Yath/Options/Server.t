use Test2::V0 -target => 'App::Yath::Options::Server';

my $parse = \&App::Yath::Options::Server::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "default values" => sub {
    my $server = $parse->([], no_set_env => 1)->{settings}{server};

    is($server->{ephemeral},   undef, "ephemeral defaults to undef");
    is($server->{shell},       0,     "shell defaults to 0");
    is($server->{daemon},      0,     "daemon defaults to 0");
    is($server->{single_user}, 0,     "single_user defaults to 0");
    is($server->{single_run},  0,     "single_run defaults to 0");
    is($server->{no_upload},   0,     "no_upload defaults to 0");
    is($server->{email},       undef, "email defaults to undef");
};

subtest "ephemeral Auto type: no value uses autofill 'Auto'" => sub {
    my $server = $parse->(['--ephemeral'], no_set_env => 1)->{settings}{server};
    is($server->{ephemeral}, 'Auto', "--ephemeral without value uses 'Auto'");
};

subtest "ephemeral Auto type: explicit db type" => sub {
    my $server = $parse->(['--ephemeral=PostgreSQL'], no_set_env => 1)->{settings}{server};
    is($server->{ephemeral}, 'PostgreSQL', "--ephemeral=PostgreSQL sets explicit db type");
};

subtest "ephemeral Auto type: SQLite" => sub {
    my $server = $parse->(['--ephemeral=SQLite'], no_set_env => 1)->{settings}{server};
    is($server->{ephemeral}, 'SQLite', "--ephemeral=SQLite is accepted");
};

subtest "daemon Bool flag" => sub {
    my $server = $parse->(['--daemon'], no_set_env => 1)->{settings}{server};
    is($server->{daemon}, 1, "--daemon sets daemon to 1");
};

subtest "shell Bool flag" => sub {
    my $server = $parse->(['--shell'], no_set_env => 1)->{settings}{server};
    is($server->{shell}, 1, "--shell sets shell to 1");
};

subtest "single_user Bool flag" => sub {
    my $server = $parse->(['--single-user'], no_set_env => 1)->{settings}{server};
    is($server->{single_user}, 1, "--single-user sets single_user to 1");
};

subtest "single_run Bool flag" => sub {
    my $server = $parse->(['--single-run'], no_set_env => 1)->{settings}{server};
    is($server->{single_run}, 1, "--single-run sets single_run to 1");
};

subtest "no_upload Bool flag" => sub {
    my $server = $parse->(['--no-upload'], no_set_env => 1)->{settings}{server};
    is($server->{no_upload}, 1, "--no-upload sets no_upload to 1");
};

subtest "email Scalar option" => sub {
    my $server = $parse->(['--email', 'admin@example.com'], no_set_env => 1)->{settings}{server};
    is($server->{email}, 'admin@example.com', "--email sets email");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{server}, ['Getopt::Yath::Settings::Group'], "server settings is a Settings::Group");
};

done_testing;
