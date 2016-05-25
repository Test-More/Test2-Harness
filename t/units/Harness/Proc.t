use Test2::Bundle::Extended -target => 'Test2::Harness::Proc';
use Time::HiRes qw/sleep/;
use PerlIO;
use IO::Handle;

skip_all "This test cannot run on windows"
    if $^O eq 'MSWin32';

can_ok($CLASS, qw/file pid in_fh out_fh err_fh exit lines idx/);

sub spawn {
    my ($in_read, $in_write, $out_read, $out_write, $err_read, $err_write);
    pipe($in_read, $in_write) or die "Could not open pipe!";
    pipe($out_read, $out_write) or die "Could not open pipe!";
    pipe($err_read, $err_write) or die "Could not open pipe!";

    my $orig = select $out_write; $| = 1;
    select $err_write; $| = 1;
    select $in_write;  $| = 1;
    select $orig; $| = 1;

    my $pid = fork;
    die "Could not fork" unless defined $pid;

    return $CLASS->new(
        pid    => $pid,
        file   => 'fake.pl',
        in_fh  => $in_write,
        out_fh => $out_read,
        err_fh => $err_read,
        @_,
    ) if $pid;

    print $out_write "Started\n";

    while(my $cmd = <$in_read>) {
        chomp($cmd);
        if ($cmd =~ m/^(p|s) STDOUT: (.*)$/) {
            print $out_write $2;
            print $out_write "\n" if $1 eq 's';
        }
        elsif ($cmd =~ m/^(p|s) STDERR: (.*)$/) {
            print $err_write $2;
            print $err_write "\n" if $1 eq 's';
        }
        elsif ($cmd =~ m/^EXIT: (\d+)$/) {
            exit $1;
        }
        else {
            print STDERR "Unrecognized command: |$cmd|\n";
        }
    }
}

sub do_to {
    my ($timeout, $run, @args) = @_;
    my @caller = caller;

    $SIG{ALRM} = sub { die "timeout at $caller[1] line $caller[2].\n" };
    alarm $timeout;
    $run->(@args);
    alarm 0;
}

subtest init => sub {
    like(
        dies { $CLASS->new(pid => 1, in_fh => 1, out_fh => 1, file => 1, $_ => undef) },
        qr/'$_' is a required attribute/,
        "Need '$_' attribute"
    ) for qw/pid in_fh out_fh file/;

    my $x = "";
    open(my $fh, '>', \$x);
    my $one = $CLASS->new(pid => 1, in_fh => $fh, out_fh => $fh, file => 1);
    isa_ok($one, $CLASS);
};

subtest encoding => sub {
    my $x = "";
    open(my $fh1, '>', \$x);
    open(my $fh2, '<', \$x);
    open(my $fh3, '<', \$x);

    my $one = $CLASS->new(pid => 1, file => 1, in_fh => $fh1, out_fh => $fh2, err_fh => $fh3);
    $one->encoding('utf8');

    for my $fh ($fh1, $fh2, $fh3) {
        my $layers = { map {$_ => 1} PerlIO::get_layers($fh) };
        ok($layers->{utf8}, "Now utf8");
    }
};

subtest IPC => sub {
    my $one = spawn();
    isa_ok($one, $CLASS);
    do_to 2 => sub { sleep 0.2 until $one->get_out_line(peek => 1) };
    is($one->get_out_line(peek => 1), "Started\n", "Got line");
    is($one->get_out_line, "Started\n", "Last call only peeked");

    do_to 2 => sub { ok(!$one->get_out_line, "get_line is not blocking") };

    $one->write("s STDERR: hello\n");
    do_to 2 => sub { sleep 0.2 until $one->get_err_line(peek => 1) };
    is($one->get_err_line(peek => 1), "hello\n", "Got line");
    is($one->get_err_line, "hello\n", "Last call only peeked");

    do_to 2 => sub { ok(!$one->is_done, "not done yet") };
    $one->write("p STDOUT: incomplete line\n");
    $one->write("EXIT: 0\n");
    do_to 2 => sub { $one->wait };
    is($one->exit, 0, "exited 0");
    ok($one->is_done, "done_now");
    is($one->get_out_line, 'incomplete line', "got line with no newline");

    is(
        [$one->seen_out_lines],
        [
            "Started\n",
            "incomplete line"
        ],
        "Got lines"
    );

    is(
        [$one->seen_err_lines],
        ["hello\n"],
        "got err lines"
    );
};

done_testing;
