use Test2::V0; # -target => 'Test2::Harness::Collector::Child'

# Child.pm requires being "inside a collector" (T2_HARNESS_PIPE_COUNT env var
# or $STDERR_APIPE set) to do most operations, including import(). We test what
# we can safely: that the module loads and that its protection logic works.

subtest 'module can be loaded' => sub {
    ok(lives { require Test2::Harness::Collector::Child }, "module loads without error");
    ok($INC{'Test2/Harness/Collector/Child.pm'}, "module is in %INC");
};

subtest 'import dies outside of collector' => sub {
    # Clear any collector environment
    local $ENV{T2_HARNESS_PIPE_COUNT};
    delete $ENV{T2_HARNESS_PIPE_COUNT};

    # Also ensure $STDERR_APIPE is not set
    local $Test2::Harness::Collector::Child::STDERR_APIPE = undef;
    local $Test2::Harness::Collector::Child::STDOUT_APIPE = undef;

    like(
        dies { Test2::Harness::Collector::Child->import('send_event') },
        qr/do not appear to be inside a collector/,
        "import() dies outside of collector context"
    );
};

subtest 'STDOUT_APIPE dies outside collector' => sub {
    local $ENV{T2_HARNESS_PIPE_COUNT};
    delete $ENV{T2_HARNESS_PIPE_COUNT};
    local $Test2::Harness::Collector::Child::STDERR_APIPE = undef;
    local $Test2::Harness::Collector::Child::STDOUT_APIPE = undef;

    like(
        dies { Test2::Harness::Collector::Child::STDOUT_APIPE() },
        qr/do not appear to be inside a collector/,
        "STDOUT_APIPE dies outside of collector context"
    );
};

subtest 'STDERR_APIPE dies outside collector' => sub {
    local $ENV{T2_HARNESS_PIPE_COUNT};
    delete $ENV{T2_HARNESS_PIPE_COUNT};
    local $Test2::Harness::Collector::Child::STDERR_APIPE = undef;

    like(
        dies { Test2::Harness::Collector::Child::STDERR_APIPE() },
        qr/do not appear to be inside a collector/,
        "STDERR_APIPE dies outside of collector context"
    );
};

subtest 'send_event dies outside collector' => sub {
    local $ENV{T2_HARNESS_PIPE_COUNT};
    delete $ENV{T2_HARNESS_PIPE_COUNT};
    local $Test2::Harness::Collector::Child::STDERR_APIPE = undef;
    local $Test2::Harness::Collector::Child::STDOUT_APIPE = undef;

    like(
        dies { Test2::Harness::Collector::Child::send_event() },
        qr/do not appear to be inside a collector/,
        "send_event dies outside of collector context"
    );
};

done_testing;
