use Test2::V0 -target => 'App::Yath::Options::IPCAll';

my $parse = \&App::Yath::Options::IPCAll::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "includes IPC options (ipc group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{ipc}, "ipc group is present (included from IPC)");
    my $ipc = $settings->{ipc};
    is($ipc->{dir_order},      [qw/base temp/], "dir_order default from included IPC");
    is($ipc->{prefix},         'IPC',           "prefix default from included IPC");
    is($ipc->{allow_multiple}, 0,               "allow_multiple default from included IPC");
};

subtest "allow_non_daemon defaults to 1" => sub {
    my $ipc = $parse->([], no_set_env => 1)->{settings}{ipc};
    is($ipc->{allow_non_daemon}, 1, "allow_non_daemon defaults to 1");
};

subtest "allow_non_daemon can be disabled" => sub {
    my $ipc = $parse->(['--no-ipc-allow-non-daemon'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{allow_non_daemon}, 0, "--no-ipc-allow-non-daemon disables allow_non_daemon");
};

subtest "IPC options still work" => sub {
    my $ipc = $parse->(['--ipc-dir', '/tmp/test'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{dir}, '/tmp/test', "ipc-dir still parseable via IPCAll");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{ipc}, ['Getopt::Yath::Settings::Group'], "ipc settings is a Settings::Group");
};

done_testing;
