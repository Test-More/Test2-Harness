use Test2::V0 -target => 'Test2::Harness::IPC::Protocol::AtomicPipe::Connection';

use POSIX qw/mkfifo/;
use File::Temp qw/tempdir/;

subtest 'module loads' => sub {
    ok(CLASS(), "CLASS() is defined");
    is(CLASS(), 'Test2::Harness::IPC::Protocol::AtomicPipe::Connection', "CLASS() is correct");
    isa_ok(CLASS(), ['Test2::Harness::IPC::Connection'], "is a Connection");
};

subtest 'new requires fifo' => sub {
    like(
        dies { CLASS()->new() },
        qr/'fifo' is a required attribute/,
        "new() without fifo croaks"
    );
};

subtest 'constructor with fifo' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/test.fifo";
    mkfifo($file, 0700) or die "mkfifo: $!";

    my $obj = CLASS()->new(fifo => $file);
    isa_ok($obj, [CLASS()],                   "new() returns Connection object");
    is($obj->fifo(),     $file,               "fifo attribute set");
    is($obj->active(),   1,                   "active defaults to 1");
    is($obj->protocol(), 'Test2::Harness::IPC::Protocol::AtomicPipe',
        "protocol defaults to AtomicPipe class");
};

subtest 'TO_JSON returns connect data' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/tojson.fifo";
    mkfifo($file, 0700) or die "mkfifo: $!";

    my $obj = CLASS()->new(fifo => $file);
    my $data = $obj->TO_JSON();
    is($data->{protocol},  'Test2::Harness::IPC::Protocol::AtomicPipe', "TO_JSON protocol is correct");
    is($data->{connect}[0], $file, "TO_JSON connect[0] is the fifo path");
    is($data->{connect}[1], undef, "TO_JSON connect[1] is undef (port)");
};

subtest 'terminate deactivates the connection' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/term.fifo";
    mkfifo($file, 0700) or die "mkfifo: $!";

    my $obj = CLASS()->new(fifo => $file);
    ok($obj->active(), "active before terminate");

    $obj->terminate();
    ok(!$obj->active(),      "not active after terminate");
    ok($obj->deactivated(),  "deactivated timestamp set");
};

subtest 'expired returns true when deactivated and no pending requests' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/exp.fifo";
    mkfifo($file, 0700) or die "mkfifo: $!";

    my $obj = CLASS()->new(fifo => $file);
    $obj->terminate();

    ok($obj->expired(), "expired returns true when inactive with no requests");
};

subtest 'send_message dies when inactive' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = "$dir/send.fifo";
    mkfifo($file, 0700) or die "mkfifo: $!";

    my $obj = CLASS()->new(fifo => $file);
    $obj->terminate();

    like(
        dies { $obj->send_message({}) },
        qr/Disconnected pipe/,
        "send_message on terminated connection croaks"
    );
};

done_testing;
