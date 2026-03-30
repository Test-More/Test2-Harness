use Test2::V0 -target => 'Test2::Harness::Plugin';

# Module loads and class constant available
ok(CLASS, "CLASS constant is set");
is(CLASS, 'Test2::Harness::Plugin', "CLASS is correct");

subtest to_json => sub {
    is(CLASS->TO_JSON, 'Test2::Harness::Plugin', "TO_JSON returns class name when called as class");

    my $obj = bless {}, CLASS;
    is($obj->TO_JSON, 'Test2::Harness::Plugin', "TO_JSON returns class name when called on object");
};

subtest no_op_methods => sub {
    my $obj = bless {}, CLASS;
    is($obj->tick,              undef, "tick returns undef");
    is($obj->run_queued,        undef, "run_queued returns undef");
    is($obj->run_complete,      undef, "run_complete returns undef");
    is($obj->run_halted,        undef, "run_halted returns undef");
    is($obj->client_setup,      undef, "client_setup returns undef");
    is($obj->client_teardown,   undef, "client_teardown returns undef");
    is($obj->client_finalize,   undef, "client_finalize returns undef");
    is($obj->instance_setup,    undef, "instance_setup returns undef");
    is($obj->instance_teardown, undef, "instance_teardown returns undef");
    is($obj->instance_finalize, undef, "instance_finalize returns undef");
};

subtest deprecated_methods => sub {
    my $obj = bless {}, CLASS;

    like(
        dies { $obj->redirect_io },
        qr/redirect_io.*deprecated/i,
        "redirect_io dies with deprecation message"
    );

    like(
        dies { $obj->shellcall },
        qr/shellcall.*deprecated/i,
        "shellcall dies with deprecation message"
    );
};

subtest sanity_checks => sub {
    # Build a package that has one of the "insane" methods
    {
        package My::BadPlugin;
        use parent -norequire => 'Test2::Harness::Plugin';
        sub handle_event { }
    }

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    My::BadPlugin->sanity_checks;

    ok(scalar @warnings, "sanity_checks warns about deprecated method implementation");
    like($warnings[0], qr/handle_event/, "warning mentions handle_event");
};

subtest sanity_checks_clean => sub {
    {
        package My::GoodPlugin;
        use parent -norequire => 'Test2::Harness::Plugin';
    }

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    My::GoodPlugin->sanity_checks;

    is(scalar @warnings, 0, "sanity_checks does not warn for clean plugin");
};

subtest insane_methods => sub {
    my @methods = CLASS->insane_methods;
    ok(scalar @methods > 0, "insane_methods returns a list");
    ok((grep { $_ eq 'handle_event' } @methods), "list includes 'handle_event'");
};

done_testing;
