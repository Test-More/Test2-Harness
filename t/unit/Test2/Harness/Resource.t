use Test2::V0 -target => 'Test2::Harness::Resource';

subtest abstract_methods_croak => sub {
    my $obj = bless {}, CLASS;

    like(
        dies { $obj->applicable },
        qr/does not implement/,
        "applicable croaks"
    );

    like(
        dies { $obj->available },
        qr/does not implement/,
        "available croaks"
    );

    like(
        dies { $obj->assign },
        qr/does not implement/,
        "assign croaks"
    );

    like(
        dies { $obj->release },
        qr/does not implement/,
        "release croaks"
    );

    like(
        dies { $obj->subprocess_run },
        qr/does not implement/,
        "subprocess_run croaks"
    );
};

subtest default_methods => sub {
    my $obj = bless {}, CLASS;

    ok(!$obj->spawns_process, "spawns_process returns false by default");
    ok(!$obj->is_job_limiter, "is_job_limiter returns false by default");

    is($obj->resource_name,   'Resource',  "resource_name has a default");
    is($obj->resource_io_tag, 'RESOURCE',  "resource_io_tag has a default");

    # These should not die
    ok(lives { $obj->teardown }, "teardown does not die");
    ok(lives { $obj->tick },     "tick does not die");
    ok(lives { $obj->cleanup },  "cleanup does not die");
};

subtest sort_weight => sub {
    is(CLASS->sort_weight, 50, "default sort_weight is 50");

    {
        package FakeJobLimiter;
        use parent -norequire => 'Test2::Harness::Resource';
        sub is_job_limiter { 1 }
    }

    is(FakeJobLimiter->sort_weight, 100, "job limiter sort_weight is 100");
};

subtest spawn_class => sub {
    is(CLASS->spawn_class, CLASS, "spawn_class returns the class name when called as class");

    my $obj = bless {}, CLASS;
    is($obj->spawn_class, CLASS, "spawn_class returns the class name from object");
};

subtest status_data => sub {
    my $obj = bless {}, CLASS;
    my @data = $obj->status_data;
    is(scalar @data, 0, "status_data returns empty list by default");
};

done_testing;
