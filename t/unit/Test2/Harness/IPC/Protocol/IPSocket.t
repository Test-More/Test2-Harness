use Test2::V0;

# Test2::Harness::IPC::Protocol::IPSocket has a BEGIN block that dies
# with "This protocol has not yet been implemented", so we cannot load
# the module normally.  We test two things:
#   1. The module file is present in the distribution.
#   2. Attempting to load the module raises exactly that error.

subtest 'module file exists' => sub {
    my $file = 'lib/Test2/Harness/IPC/Protocol/IPSocket.pm';
    ok(-f $file, "IPSocket.pm exists on disk");
};

subtest 'loading the module dies with not-yet-implemented' => sub {
    my $err = do {
        local $@;
        eval { require Test2::Harness::IPC::Protocol::IPSocket };
        $@;
    };
    like($err, qr/This protocol has not yet been implemented/,
        "require IPSocket dies with expected message");
};

done_testing;
