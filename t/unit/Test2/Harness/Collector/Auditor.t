use Test2::V0 -target => 'Test2::Harness::Collector::Auditor';

subtest 'can be loaded' => sub {
    ok(CLASS(), "CLASS() returns the package name");
    ok(CLASS()->isa('Test2::Harness::Collector::Auditor'), "is correct class");
};

subtest 'init is a no-op on base class' => sub {
    my $obj = CLASS()->new();
    ok($obj, "object created via new()");
};

subtest 'abstract methods die on base class' => sub {
    my $obj = bless {}, CLASS();

    like(
        dies { $obj->audit() },
        qr/does not implement audit/,
        "audit() is abstract"
    );

    like(
        dies { $obj->pass() },
        qr/does not implement pass/,
        "pass() is abstract"
    );

    like(
        dies { $obj->fail() },
        qr/does not implement fail/,
        "fail() is abstract"
    );

    like(
        dies { $obj->has_exit() },
        qr/does not implement has_exit/,
        "has_exit() is abstract"
    );

    like(
        dies { $obj->has_plan() },
        qr/does not implement has_plan/,
        "has_plan() is abstract"
    );
};

subtest 'error messages mention the method name' => sub {
    my $obj = bless {}, CLASS();

    my $err = dies { $obj->audit() };
    ok($err, "got an error");
    like($err, qr/does not implement audit\(\)/, "error message mentions method name");

    $err = dies { $obj->has_plan() };
    like($err, qr/does not implement has_plan\(\)/, "error message mentions has_plan");
};

done_testing;
