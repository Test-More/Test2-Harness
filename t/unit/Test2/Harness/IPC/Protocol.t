use Test2::V0 -target => 'Test2::Harness::IPC::Protocol';

subtest 'module loads' => sub {
    ok(CLASS(), "CLASS() is defined");
    is(CLASS(), 'Test2::Harness::IPC::Protocol', "CLASS() is the right package");
};

subtest 'new requires protocol' => sub {
    like(
        dies { CLASS()->new() },
        qr/'protocol' is a required field/,
        "new() without protocol croaks"
    );
};

subtest 'new with protocol redirects to subclass' => sub {
    my $obj = CLASS()->new(protocol => 'Test2::Harness::IPC::Protocol::AtomicPipe');
    isa_ok($obj, ['Test2::Harness::IPC::Protocol::AtomicPipe'],
        "new() with protocol= blesses into that class");
    isa_ok($obj, ['Test2::Harness::IPC::Protocol'],
        "subclass still isa Protocol");
};

subtest 'abstract methods confess with does not implement' => sub {
    # Bless directly into the base class to test each abstract method
    my $obj = bless { protocol => 'Test2::Harness::IPC::Protocol' },
        'Test2::Harness::IPC::Protocol';

    like(dies { $obj->get_address() },            qr/does not implement get_address/,            "get_address confesses");
    like(dies { $obj->callback() },               qr/does not implement callback/,               "callback confesses");
    like(dies { $obj->refuse_new_connections() }, qr/does not implement refuse_new_connections/, "refuse_new_connections confesses");
    like(dies { $obj->active() },                 qr/does not implement active/,                 "active confesses");
    like(dies { $obj->health_check() },           qr/does not implement health_check/,           "health_check confesses");
    like(dies { $obj->start() },                  qr/does not implement start/,                  "start confesses");
    like(dies { $obj->connect() },                qr/does not implement connect/,                "connect confesses");
    like(dies { $obj->send_message() },           qr/does not implement send_message/,           "send_message confesses");
    like(dies { $obj->get_message() },            qr/does not implement get_message/,            "get_message confesses");
    like(dies { $obj->have_messages() },          qr/does not implement have_messages/,          "have_messages confesses");
    like(dies { $obj->get_request() },            qr/does not implement get_request/,            "get_request confesses");
    like(dies { $obj->send_response() },          qr/does not implement send_response/,          "send_response confesses");
    like(dies { $obj->have_requests() },          qr/does not implement have_requests/,          "have_requests confesses");
    like(dies { $obj->connections() },            qr/does not implement connections/,            "connections confesses");
};

subtest 'no-op methods do not die' => sub {
    my $obj = bless { protocol => 'Test2::Harness::IPC::Protocol' },
        'Test2::Harness::IPC::Protocol';

    my @h = $obj->handles_for_select();
    is(\@h, [], "handles_for_select returns empty list");

    ok(lives { $obj->terminate() }, "terminate() does not die");
};

subtest 'default_port returns undef' => sub {
    my $obj = bless { protocol => 'Test2::Harness::IPC::Protocol' },
        'Test2::Harness::IPC::Protocol';

    is($obj->default_port(), undef, "default_port returns undef");
};

subtest 'verify_port confesses when port is defined' => sub {
    my $obj = bless { protocol => 'Test2::Harness::IPC::Protocol' },
        'Test2::Harness::IPC::Protocol';

    ok(lives { $obj->verify_port(undef) }, "verify_port(undef) does not die");
    like(dies { $obj->verify_port(1234) }, qr/does not use ports/, "verify_port(1234) confesses");
};

done_testing;
