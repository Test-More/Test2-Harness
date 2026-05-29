use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use IO::Select;
use Compress::Zstd qw/compress decompress/;

use Test2::Harness2::Util::Socket qw/open_unix_listen connect_unix write_frame/;

my $dir = tempdir(CLEANUP => 1);

subtest listen_connect_write_read => sub {
    my $path = "$dir/a.sock";
    my $listen = open_unix_listen($path);
    ok(-S $path, "socket file created and is a socket");

    my $client = connect_unix($path);
    ok($client, "connected to the listening socket");

    my $server_conn = $listen->accept;
    ok($server_conn, "server accepted the connection");

    my $frame = compress("hello-frame");
    write_frame($client, $frame);

    my $buf = '';
    my $sel = IO::Select->new($server_conn);
    ok($sel->can_read(2), "server side became readable");
    sysread($server_conn, $buf, 65536);
    is($buf, $frame, "exact frame bytes arrived");
    is(decompress($buf), "hello-frame", "frame decodes");
};

subtest connect_missing_croaks => sub {
    my $err = dies { connect_unix("$dir/nope.sock") };
    ok($err, "connecting to a missing socket croaks");
};

subtest write_frame_returns_true => sub {
    my $path = "$dir/b.sock";
    my $listen = open_unix_listen($path);
    my $client = connect_unix($path);
    my $conn   = $listen->accept;
    is(write_frame($client, compress("x")), 1, "write_frame returns 1 on success");
};

done_testing;
