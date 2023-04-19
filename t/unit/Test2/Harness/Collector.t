use Test2::V0 -target => 'Test2::Harness::Collector';
use ok $CLASS;

use Test2::Harness::State;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use Time::HiRes qw/sleep time/;
use File::Temp qw/tempdir/;
use List::Util qw/zip/;
use Config qw/%Config/;

my @SIGNUMS  = split(' ', $Config{sig_num});
my @SIGNAMES = split(' ', $Config{sig_name});

my %SIG_LOOKUP = (
    zip(\@SIGNAMES, \@SIGNUMS),
    zip(\@SIGNUMS,  \@SIGNAMES),
);

my $tdir = tempdir(CLEANUP => 1);
my $sfile = "$tdir/state.json";
my $state = Test2::Harness::State->new(state_file => $sfile, workdir => $tdir, settings => Test2::Harness::Settings->new());

my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

my $order = 1;
my $one = $CLASS->new(
    state => $state,
    merge_outputs => 0,
    event_cb => sub {
        my $self = shift;
        my ($e) = @_;
        $w->write_message(encode_json({%$e, from_pid => $$, callback_stamp => time, order => $order++}));
    },
);

my $pid1 = $one->run(name => 'foo', type => 'foo', launch_cb => sub {
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 1}));
    print STDOUT "A line on STDOUT!\n";
    sleep 1;
    print STDERR "A line on STDERR!\n";
    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 2}));

    exit 12;
});

my $pid2 = $one->run(name => 'foo', type => 'foo', launch_cb => sub {
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 1}));
    print STDOUT "A line on STDOUT!\n";
    sleep 1;
    print STDERR "A line on STDERR!\n";
    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 2}));

    exit 0;
});

my $pid3 = $one->run(name => 'foo', type => 'foo', launch_cb => sub {
    sleep 30;

    exit 0;
});

my $pid4 = do {
    local $one->{merge_outputs} = 1;
    $one->run(name => 'foo', type => 'foo', launch_cb => sub {
        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
        print STDOUT "A line on STDOUT!\n";
        sleep 1;
        print STDERR "A line on STDERR!\n";
        $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));

        die "ooops";
    });
};

is(
    [$one->reap($pid1, $pid2)],
    [
        {all => 0, err => 0, sig => 0, dmp => 0},
        {all => 0, err => 0, sig => 0, dmp => 0},
    ],
    "Got expected exit values"
);

kill('INT', $pid3);

is(
    [$one->reap($pid3, $pid4)],
    [
        {all => 0, err => 0, sig => 0, dmp => 0}, # collector 3 forwards the signal, but does not exit due to it.
        {all => 0, err => 0, sig => 0, dmp => 0},
    ],
    "Got expected exit values"
);

$w->close();

my @got;
while (1) {
    my ($type, $val) = $r->get_line_burst_or_data;
    last unless $type;
    push @got => decode_json($val);
}

@got = sort { $a->{from_pid} <=> $b->{from_pid} || $a->{order} <=> $b->{order} || $a->{callback_stamp} <=> $b->{callback_stamp} } @got;

like(
    \@got,
    array {
        item {
            from_pid => $pid1,
            action   => 'launch',
            stream   => 'process',
        };
        item {
            from_pid => $pid1,
            stream   => "stdout",
            data     => {event_id => 1, data => "First Event"},
        };
        item {
            from_pid => $pid1,
            line     => "A line on STDERR!",
            stream   => "stderr",
        };
        item {
            from_pid => $pid1,
            line     => "A line on STDOUT!",
            stream   => "stdout",
        };
        item {
            from_pid => $pid1,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid1,
            action   => 'exit',
            stream   => 'process',
            exit     => {exit => {all => 3072, dmp => 0, err => 12, sig => 0}},
        };



        item {
            from_pid => $pid2,
            action   => 'launch',
            stream   => 'process',
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 1, data => "First Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid2,
            line     => "A line on STDERR!",
            stream   => "stderr",
        };
        item {
            from_pid => $pid2,
            line     => "A line on STDOUT!",
            stream   => "stdout",
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid2,
            action   => 'exit',
            stream   => 'process',
            exit     => {exit => {all => 0, dmp => 0, err => 0, sig => 0}},
        };


        item {
            from_pid => $pid3,
            action   => 'launch',
            stream   => 'process',
        };
        item {
            from_pid   => $pid3,
            event => {facet_data => {info => [{tag => "WARNING", debug => 1, details => qr{\Q$pid3\E: Got SIGINT, forwarding to child process}}]}},
        };
        item {
            from_pid => $pid3,
            action   => 'exit',
            stream   => 'process',
            exit     => {exit => {all => 2, dmp => 0, err => 0, sig => 2}},
        };



        item {
            from_pid => $pid4,
            action   => 'launch',
            stream   => 'process',
        };
        item {
            from_pid => $pid4,
            data     => {event_id => 1, data => "First Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            line     => "A line on STDOUT!",
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            line     => "A line on STDERR!",
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            action   => 'exit',
            stream   => 'process',
            exit     => {exit => {all => 65280, dmp => 0, err => 255, sig => 0}},
        };
        item {
            from_pid   => not_in_set($pid1, $pid2, $pid3, $pid4, $$), # We do not know the child PID, but we know it is not these.
            event => {facet_data => {errors => [{tag => "ERROR", details => qr{ooops at t/unit/Test2/Harness/Collector\.t}, fail => 1}]}},
        };

        end();
    },
    "Got all expected items"
);

($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
$order = 1;
my $two = $CLASS->new(
    state => $state,
    merge_outputs => 0,
    event_cb => sub {
        my $self = shift;
        my ($e) = @_;
        $w->write_message(encode_json({%$e, from_pid => $$, callback_stamp => time, order => $order++}));
    },
);

my $pid5 = $two->run(name => 'foo', type => 'foo', launch_cb => sub {
    $ENV{T2_FORMATTER} = 'Stream';
    my $test = __FILE__ . 'x';
    my @cmd = ($^X, (map {"-I$_"} @INC), $test);
    exec(@cmd);
});

$w->close;

$two->reap($pid5);
@got = ();
while (1) {
    my ($type, $val) = $r->get_line_burst_or_data;
    last unless $type;
    push @got => decode_json($val);
}

like(
    \@got,
    [
        {order => 1, action => 'launch', stream => 'process'},
        {
            order  => 2,
            stream => "stdout",
            data   => {facet_data => {info => [{tag => "NOTE", details => qr/Seeded srand with seed '\d+' from local date\./}]}},
        },
        {
            order  => 3,
            stream => "stdout",
            data   => {facet_data => {control => {encoding => "utf8"}}},
        },
        {
            order  => 4,
            stream => "stdout",
            data   => {facet_data => {assert => {details => "Assertion A"}}},
        },
        {order => 5, stream => "stderr", line => "STDERR! A"},
        {order => 6, stream => "stdout", line => "STDOUT! A"},
        {
            order  => 7,
            stream => "stdout",
            data   => {facet_data => {assert => {details => "Assertion B"}}},
        },
        {
            order  => 8,
            stream => "stdout",
            data   => {facet_data => {info => [{tag => "DIAG", details => "Failed test 'Assertion B'\nat t/unit/Test2/Harness/Collector.tx line 6.\n"}]}},
        },
        {order => 9, stream => "stderr", line => "STDERR! B"},
        {order => 10,  stream => "stdout", line => "STDOUT! B"},
        {
            order  => 11,
            stream => "stdout",
            data   => {facet_data => {info => [{tag => "DIAG", details => "A diag"}]}},
        },
        {
            order  => 12,
            stream => "stdout",
            data   => {facet_data => {info => [{tag => "NOTE", details => "UTF8: ще трохи"}]}},
        },
        {
            order  => 13,
            stream => "stdout",
            data   => {facet_data => {plan => {count => 2}}},
        },
        {
            order  => 14,
            stream => "stdout",
            data   => {facet_data => {control => {phase => "END"}}},
        },
        {
            order  => 15,
            action => 'exit',
            stream => 'process',
            exit   => {exit => {all => 256, err => 1, sig => 0, dmp => 0}},
        },
    ],
    "Got expected events and lines"
);

done_testing;
