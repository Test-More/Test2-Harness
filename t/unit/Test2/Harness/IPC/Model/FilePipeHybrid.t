use Test2::V0 -target => 'Test2::Harness::IPC::Model::FilePipeHybrid';
use POSIX qw/:sys_wait_h/;
use Time::HiRes qw/sleep/;

use Test2::Harness::State;
use Test2::Harness::Settings;

use ok $CLASS;

use File::Temp qw/tempdir/;

my $tdir = tempdir(CLEANUP => 1);
my $sfile = "$tdir/state.json";

my $state = Test2::Harness::State->new(state_file => $sfile, workdir => $tdir, settings => Test2::Harness::Settings->new());
$state->transaction('w' => sub { 1 });
my $one = $CLASS->new(run_id => 1, state => $state);

my ($read_stdout, $stdout_fh)   = $one->get_test_stdout_pair(1, 0);
my ($read_stderr, $stderr_fh)   = $one->get_test_stderr_pair(1, 0);
my ($read_events, $write_event) = $one->get_test_events_pair(1, 0);

my @stdout;
my @stderr;
my @events;

my $pid = fork // die "Could not fork: $!";
unless ($pid) {
    open(STDOUT, '>&', $stdout_fh) or die "Error opening new STDOUT: $!";
    open(STDERR, '>&', $stderr_fh) or die "Error opening new STDERR: $!";

    for (1 .. 10) {
        note("Loop $_/10");
        $write_event->({foo => 1, c => $_});
        print "Write to STDOUT 1 c$_.\n";
        print STDERR "Write to STDERR c$_.\n";
        $write_event->({foo => 2, c => $_});
        print "Write to STDOUT 2 c$_.\n";
        sleep 0.4;
    }

    exit 0;
}

while (1) {
    my $p2 = waitpid($pid, WNOHANG);
    my $x = $?;

    push @stdout => $read_stdout->();
    push @stderr => $read_stderr->();
    push @events => $read_events->();

    if ($p2 == $pid) {
        is($x, 0, "Child exited without error");
        last;
    }

    sleep 0.1;
}

chomp(@events, @stdout, @stderr);

is(
    \@events,
    [
        {'c' => 1,  'foo' => 1},
        {'c' => 1,  'foo' => 2},
        {'c' => 2,  'foo' => 1},
        {'c' => 2,  'foo' => 2},
        {'c' => 3,  'foo' => 1},
        {'c' => 3,  'foo' => 2},
        {'c' => 4,  'foo' => 1},
        {'c' => 4,  'foo' => 2},
        {'c' => 5,  'foo' => 1},
        {'c' => 5,  'foo' => 2},
        {'c' => 6,  'foo' => 1},
        {'c' => 6,  'foo' => 2},
        {'c' => 7,  'foo' => 1},
        {'c' => 7,  'foo' => 2},
        {'c' => 8,  'foo' => 1},
        {'c' => 8,  'foo' => 2},
        {'c' => 9,  'foo' => 1},
        {'c' => 9,  'foo' => 2},
        {'c' => 10, 'foo' => 1},
        {'c' => 10, 'foo' => 2},
    ],
    "Got all events",
);

is(
    \@stdout,
    [
        'Write to STDOUT 1 c1.',
        'Write to STDOUT 2 c1.',
        'Write to STDOUT 1 c2.',
        'Write to STDOUT 2 c2.',
        'Write to STDOUT 1 c3.',
        'Write to STDOUT 2 c3.',
        'Write to STDOUT 1 c4.',
        'Write to STDOUT 2 c4.',
        'Write to STDOUT 1 c5.',
        'Write to STDOUT 2 c5.',
        'Write to STDOUT 1 c6.',
        'Write to STDOUT 2 c6.',
        'Write to STDOUT 1 c7.',
        'Write to STDOUT 2 c7.',
        'Write to STDOUT 1 c8.',
        'Write to STDOUT 2 c8.',
        'Write to STDOUT 1 c9.',
        'Write to STDOUT 2 c9.',
        'Write to STDOUT 1 c10.',
        'Write to STDOUT 2 c10.',
    ],
    "Got all STDOUT events",
);

is(
    \@stderr,
    [
        'Write to STDERR c1.',
        'Write to STDERR c2.',
        'Write to STDERR c3.',
        'Write to STDERR c4.',
        'Write to STDERR c5.',
        'Write to STDERR c6.',
        'Write to STDERR c7.',
        'Write to STDERR c8.',
        'Write to STDERR c9.',
        'Write to STDERR c10.',
    ],
    "Got all STDERR events",
);

my $reader1 = $one->add_renderer();
my $reader2 = $one->add_renderer();

$one->render_event({foo => 1});
$one->render_event({foo => 2});
$one->render_event({foo => 3});

$pid = fork // die "Could not fork: $!";
unless ($pid) {
    $one->render_event({bar => 1});
    $one->render_event({bar => 2});
    $one->render_event({bar => 3});
    exit 0;
}
waitpid($pid, 0);
is($?, 0, "Child exited without error");

my @one = $reader1->();
my @two = $reader2->();

is(
    \@one,
    [
        {foo => 1}, {foo => 2}, {foo => 3},
        {bar => 1}, {bar => 2}, {bar => 3},
    ],
    "First renderer got all events"
);

is(
    \@two,
    [
        {foo => 1}, {foo => 2}, {foo => 3},
        {bar => 1}, {bar => 2}, {bar => 3},
    ],
    "second renderer got all events"
);

is(@{$state->data->ipc_model->{render_files}->{1} // []}, 2, "2 render files");
is(@{$state->data->ipc_model->{render_pipes}->{1} // []}, 0, "0 render pipes");

is([$reader1->()], [], "Got nothing, did not block");

$one->finish();

is([$reader1->()], [undef], "Terminated render list with a null/undef");
is([$reader2->()], [undef], "Terminated render list with a null/undef");

done_testing;

1;
