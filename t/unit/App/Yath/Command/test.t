use Test2::V0 -target => 'App::Yath::Command::test';
# HARNESS-DURATION-SHORT

use ok $CLASS;

use Errno();
use Test2::Harness::Settings();
use Test2::Harness::Util::JSON qw/encode_json/;

use constant SETTINGS        => App::Yath::Command::test::SETTINGS();
use constant RENDERERS       => App::Yath::Command::test::RENDERERS();
use constant RENDERER_READER => App::Yath::Command::test::RENDERER_READER();
use constant ASSERTS_SEEN    => App::Yath::Command::test::ASSERTS_SEEN();

# render() reads a pipe and drives renderers; it needs no run behind it. Build
# the object directly. Note ipc() is lazy and self-building, so render() always
# gets a real Test2::Harness::IPC. That is harmless here: it installs no signal
# handlers until start(), and wait() returns immediately with no processes.
sub build_cmd {
    my ($reader, @renderers) = @_;

    my $settings = Test2::Harness::Settings->new(
        harness => {plugins => []},
        logging => {log     => 0},
    );

    return bless(
        {
            SETTINGS()        => $settings,
            RENDERERS()       => \@renderers,
            RENDERER_READER() => $reader,
        },
        $CLASS,
    );
}

sub event_line {
    my ($fd) = @_;
    return encode_json({facet_data => $fd}) . "\n";
}

# Runs $cmd->render() under an alarm. Returns 1 if it returned on its own,
# 0 if the alarm had to break it out.
sub render_under_alarm {
    my ($cmd, $timeout) = @_;

    local $SIG{ALRM} = sub { die "render-still-running\n" };

    alarm $timeout;
    my $ok  = eval { $cmd->render(); 1 };
    my $err = $@;
    alarm 0;

    return 1 if $ok;

    die $err unless $err eq "render-still-running\n";

    return 0;
}

subtest eof_ends_the_loop => sub {
    pipe(my $r, my $w) or die "Could not create pipe: $!";
    $w->autoflush(1);

    print $w event_line({assert => {pass => 1}});
    close($w);

    my $cmd = build_cmd($r);

    ok(render_under_alarm($cmd, 10), "loop ended on EOF");
    is($cmd->{+ASSERTS_SEEN}, 1, "processed the event before EOF");
};

subtest live_writer_does_not_end_the_loop => sub {
    pipe(my $r, my $w) or die "Could not create pipe: $!";

    # Without autoflush nothing is ever readable and the test proves nothing.
    $w->autoflush(1);

    print $w event_line({assert => {pass => 1}});

    my $cmd = build_cmd($r);

    # The writer stays open and the pipe goes empty. render() must still be
    # looping when the alarm fires; returning would mean it mistook "nothing
    # yet" for EOF and truncated a healthy run.
    ok(!render_under_alarm($cmd, 2), "render() did not return while the writer was alive");
    is($cmd->{+ASSERTS_SEEN}, 1, "processed the event that was available");

    close($w);
};

subtest null_sentinel_ends_the_loop => sub {
    pipe(my $r, my $w) or die "Could not create pipe: $!";
    $w->autoflush(1);

    # The collector and auditor end the stream with a literal JSON null. That
    # path must keep working, with the writer still open.
    print $w "null\n";

    my $cmd = build_cmd($r);

    ok(render_under_alarm($cmd, 10), "render() returned on the null sentinel");

    close($w);
};

subtest partial_line_at_eof_is_reported => sub {
    pipe(my $r, my $w) or die "Could not create pipe: $!";
    $w->autoflush(1);

    print $w event_line({assert => {pass => 1}});
    print $w '{"facet_data":{"assert"';    # no newline, writer then goes away
    close($w);

    my $cmd = build_cmd($r);

    my $stderr = "";
    my $returned;
    {
        local *STDERR;
        open(STDERR, '>', \$stderr) or die "Could not redirect STDERR: $!";
        $returned = render_under_alarm($cmd, 10);
    }

    ok($returned, "render() returned instead of dying on the fragment");
    like($stderr, qr/Incomplete event discarded/,  "reported the incomplete event");
    like($stderr, qr/\Q{"facet_data":{"assert"\E/, "included the fragment");
};

subtest oversized_fragment_is_truncated => sub {
    pipe(my $r, my $w) or die "Could not create pipe: $!";
    $w->autoflush(1);

    print $w '{"facet_data":' . ('x' x 5000);    # no newline
    close($w);

    my $cmd = build_cmd($r);

    my $stderr = "";
    my $returned;
    {
        local *STDERR;
        open(STDERR, '>', \$stderr) or die "Could not redirect STDERR: $!";
        $returned = render_under_alarm($cmd, 10);
    }

    ok($returned, "render() returned");
    like($stderr, qr/\Q... (truncated)\E/, "bounded the reported fragment");
    ok(length($stderr) < 500, "did not dump the whole fragment") or diag(length($stderr));
};

# A renderer that leaves a stale errno behind.
{

    package Fake::Renderer::DirtyErrno;

    sub new { return bless({}, shift) }

    sub step { $! = Errno::EAGAIN(); return }

    sub render_event { return }
}

subtest renderer_in_the_loop_still_reaches_eof => sub {
    # The only coverage where render() actually drives a renderer. It also
    # exercises a renderer leaving a stale errno behind; on this perl that
    # cannot fail, because the value it leaves is the one PerlIO retries past.
    pipe(my $r, my $w) or die "Could not create pipe: $!";
    $w->autoflush(1);

    print $w event_line({assert => {pass => 1}});
    print $w '{"facet_data":{"assert"';    # partial, then EOF
    close($w);

    my $cmd = build_cmd($r, Fake::Renderer::DirtyErrno->new);

    my $stderr = "";
    my $returned;
    {
        local *STDERR;
        open(STDERR, '>', \$stderr) or die "Could not redirect STDERR: $!";
        $returned = render_under_alarm($cmd, 10);
    }

    ok($returned, "reached EOF despite a renderer leaving EAGAIN in errno");
    is($cmd->{+ASSERTS_SEEN}, 1, "processed the complete event first");
};

done_testing;
