use Test2::V0;

# Test2::Harness::IPC::Protocol::IPSocket::Connection has a BEGIN block that
# dies with "This protocol has not yet been implemented", so it cannot be
# loaded normally.  We verify the file is present and that loading it produces
# the expected error.

subtest 'module file exists' => sub {
    my $file = 'lib/Test2/Harness/IPC/Protocol/IPSocket/Connection.pm';
    ok(-f $file, "IPSocket/Connection.pm exists on disk");
};

subtest 'loading the module dies with not-yet-implemented' => sub {
    my $err = do {
        local $@;
        eval { require Test2::Harness::IPC::Protocol::IPSocket::Connection };
        $@;
    };
    like($err, qr/This protocol has not yet been implemented/,
        "require IPSocket::Connection dies with expected message");
};

done_testing;
