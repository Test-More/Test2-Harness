use Test2::V0 -target => 'Test2::Harness::IPC::Protocol::AtomicPipe';

use POSIX qw/mkfifo/;
use File::Temp qw/tempdir/;

subtest 'module loads' => sub {
    ok(CLASS(), "CLASS() is defined");
    is(CLASS(), 'Test2::Harness::IPC::Protocol::AtomicPipe', "CLASS() is correct");
    isa_ok(CLASS(), ['Test2::Harness::IPC::Protocol'], "is a Protocol");
};

subtest 'constructor defaults' => sub {
    my $obj = CLASS()->new();
    isa_ok($obj, [CLASS()], "new() returns an AtomicPipe object");
    is($obj->active(),    0,   "active defaults to 0");
    is($obj->wait_time(), 0.2, "wait_time defaults to 0.2");
    is($obj->protocol(),  CLASS(), "protocol is the class name");
    is($obj->read_file(), undef, "read_file is undef before start");
    is($obj->read_pipe(), undef, "read_pipe is undef before start");
};

subtest 'get_address returns the file path' => sub {
    my $addr = CLASS()->get_address('/tmp/test.fifo');
    is($addr, '/tmp/test.fifo', "get_address echoes back the file path");
};

subtest 'default_port and verify_port' => sub {
    my $obj = CLASS()->new();
    is($obj->default_port(), undef, "default_port is undef");
    ok(lives { $obj->verify_port(undef) }, "verify_port(undef) does not die");
    like(dies { $obj->verify_port(9999) }, qr/does not use ports/, "verify_port(defined) confesses");
};

subtest 'connections is empty before start' => sub {
    my $obj = CLASS()->new();
    my @cons = $obj->connections();
    is(\@cons, [], "connections() returns empty list initially");
};

subtest 'handles_for_select returns nothing when inactive' => sub {
    my $obj = CLASS()->new();
    my @h = $obj->handles_for_select();
    is(\@h, [], "handles_for_select returns empty list when not active");
};

subtest 'health_check on inactive object' => sub {
    my $obj = CLASS()->new();
    is($obj->health_check(), 0, "health_check returns 0 when not active");
};

subtest 'start requires a file argument' => sub {
    my $obj = CLASS()->new();
    like(dies { $obj->start() }, qr/'file' is a required argument/, "start() with no arg croaks");
};

subtest 'start with fifo path activates the object' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/test.fifo";

    my $obj = CLASS()->new();
    $obj->start($file);

    ok($obj->active(),            "active is true after start");
    is($obj->read_file(), $file,  "read_file set after start");
    ok($obj->read_pipe(),         "read_pipe is populated after start");

    $obj->terminate();
    ok(!$obj->active(), "active is false after terminate");
};

subtest 'start on already-active pipe croaks' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/test2.fifo";

    my $obj = CLASS()->new();
    $obj->start($file);
    like(dies { $obj->start($file) }, qr/Pipe is already active/, "second start croaks");
    $obj->terminate();
};

subtest 'callback requires active pipe' => sub {
    my $obj = CLASS()->new();
    like(dies { $obj->callback() }, qr/Inactive pipe/, "callback on inactive pipe croaks");
};

subtest 'callback on active pipe returns connect data' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/cb.fifo";

    my $obj = CLASS()->new();
    $obj->start($file);

    my $cb = $obj->callback();
    is($cb->{protocol}, CLASS(),  "callback protocol is the class name");
    is($cb->{connect}[0], $file, "callback connect[0] is the fifo path");
    $obj->terminate();
};

subtest 'refuse_new_connections removes fifo' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/refuse.fifo";

    my $obj = CLASS()->new();
    $obj->start($file);
    ok(-e $file, "fifo exists after start");

    $obj->refuse_new_connections();
    ok(!-e $file, "fifo removed after refuse_new_connections");
    $obj->terminate();
};

subtest 'have_messages and have_requests default to 0' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/msgs.fifo";

    my $obj = CLASS()->new();
    $obj->start($file);
    is($obj->have_messages(), 0, "have_messages is 0 on fresh object");
    is($obj->have_requests(), 0, "have_requests is 0 on fresh object");
    $obj->terminate();
};

done_testing;
