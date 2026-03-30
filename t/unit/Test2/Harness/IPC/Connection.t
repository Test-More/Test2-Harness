use Test2::V0 -target => 'Test2::Harness::IPC::Connection';

subtest 'module loads' => sub {
    ok(CLASS(), "CLASS() is defined");
    is(CLASS(), 'Test2::Harness::IPC::Connection', "CLASS() is correct");
};

subtest 'new requires protocol' => sub {
    like(
        dies { CLASS()->new() },
        qr/'protocol' is a required field/,
        "new() without protocol croaks"
    );
};

subtest 'constructor with protocol' => sub {
    my $obj = CLASS()->new(protocol => CLASS());
    isa_ok($obj, [CLASS()],     "new() returns a Connection object");
    is($obj->protocol(), CLASS(), "protocol attribute is set");
};

subtest 'abstract methods confess with does not implement' => sub {
    my $obj = CLASS()->new(protocol => CLASS());

    like(dies { $obj->callback() },      qr/does not implement callback/,      "callback confesses");
    like(dies { $obj->active() },        qr/does not implement active/,        "active confesses");
    like(dies { $obj->health_check() },  qr/does not implement health_check/,  "health_check confesses");
    like(dies { $obj->expired() },       qr/does not implement expired/,       "expired confesses");
    like(dies { $obj->send_message() },  qr/does not implement send_message/,  "send_message confesses");
    like(dies { $obj->send_request() },  qr/does not implement send_request/,  "send_request confesses");
    like(dies { $obj->get_response() },  qr/does not implement get_response/,  "get_response confesses");
};

subtest 'no-op methods do not die' => sub {
    my $obj = CLASS()->new(protocol => CLASS());

    my @h = $obj->handles_for_select();
    is(\@h, [], "handles_for_select returns empty list");

    ok(lives { $obj->terminate() }, "terminate() does not die");
};

done_testing;
