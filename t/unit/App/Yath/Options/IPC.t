use Test2::V0 -target => 'App::Yath::Options::IPC';

my $parse = \&App::Yath::Options::IPC::parse_options;

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/T2_HARNESS_IPC_DIR YATH_IPC_DIR/;

    my $ipc = $parse->([], no_set_env => 1)->{settings}{ipc};

    is($ipc->{dir_order},      [qw/base temp/], "dir_order defaults to [base, temp]");
    is($ipc->{prefix},         'IPC',           "prefix defaults to 'IPC'");
    is($ipc->{dir},            undef,           "dir defaults to undef");
    is($ipc->{protocol},       undef,           "protocol defaults to undef");
    is($ipc->{address},        undef,           "address defaults to undef");
    is($ipc->{file},           undef,           "file defaults to undef");
    is($ipc->{port},           undef,           "port defaults to undef");
    is($ipc->{peer_pid},       undef,           "peer_pid defaults to undef");
    is($ipc->{allow_multiple}, 0,               "allow_multiple defaults to 0");
};

subtest "ipc-dir can be set via CLI" => sub {
    my $ipc = $parse->(['--ipc-dir', '/tmp/ipc'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{dir}, '/tmp/ipc', "--ipc-dir sets dir");
};

subtest "ipc-dir from env var T2_HARNESS_IPC_DIR" => sub {
    local $ENV{T2_HARNESS_IPC_DIR} = '/tmp/from-env';
    my $ipc = $parse->([], no_set_env => 1)->{settings}{ipc};
    is($ipc->{dir}, '/tmp/from-env', "T2_HARNESS_IPC_DIR populates dir");
};

subtest "ipc-dir from env var YATH_IPC_DIR" => sub {
    local %ENV = %ENV;
    delete $ENV{T2_HARNESS_IPC_DIR};
    local $ENV{YATH_IPC_DIR} = '/tmp/yath-ipc';
    my $ipc = $parse->([], no_set_env => 1)->{settings}{ipc};
    is($ipc->{dir}, '/tmp/yath-ipc', "YATH_IPC_DIR populates dir");
};

subtest "protocol normalize: short name gets namespace prepended" => sub {
    my $ipc = $parse->(['--ipc-protocol', 'AtomicPipe'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{protocol}, 'Test2::Harness::IPC::Protocol::AtomicPipe',
       "short protocol name is expanded to full namespace");
};

subtest "protocol normalize: fully-qualified name with + prefix" => sub {
    my $ipc = $parse->(['--ipc-protocol', '+Test2::Harness::IPC::Protocol::AtomicPipe'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{protocol}, 'Test2::Harness::IPC::Protocol::AtomicPipe',
       "'+' prefix is stripped, full module name is kept");
};

subtest "allow_multiple Bool flag" => sub {
    my $ipc = $parse->(['--ipc-allow-multiple'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{allow_multiple}, 1, "--ipc-allow-multiple sets flag to 1");
};

subtest "ipc-port and ipc-address options" => sub {
    my $ipc = $parse->(['--ipc-port', '9999', '--ipc-address', '127.0.0.1'], no_set_env => 1)->{settings}{ipc};
    is($ipc->{port},    '9999',      "--ipc-port is set");
    is($ipc->{address}, '127.0.0.1', "--ipc-address is set");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{ipc}, ['Getopt::Yath::Settings::Group'], "ipc settings is a Settings::Group");
};

done_testing;
