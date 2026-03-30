use Test2::V0 -target => 'Test2::Harness::Log';

# Test2::Harness::Log is a documentation-only module.
# It provides no functions or methods — just POD describing the log format.

subtest 'module loads' => sub {
    ok(CLASS, "module loaded, CLASS() returns package name");
    is(CLASS, 'Test2::Harness::Log', "target is correct");
};

subtest 'version defined' => sub {
    no strict 'refs';
    ok(defined ${"Test2::Harness::Log::VERSION"}, "VERSION is defined");
};

done_testing;
