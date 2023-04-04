use Test2::V0 -target => 'Test2::Harness::Util::Collector';
use ok $CLASS;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Time::HiRes qw/sleep time/;

my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

my $order = 1;
my $one = $CLASS->new(
    merge_outputs => 0,
    event_cb => sub {
        my $self = shift;
        my ($e) = @_;
        $w->write_message(encode_json({%$e, from_pid => $$, callback_stamp => time, order => $order++}));
    },
);

my $pid1 = $one->run(sub {
    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 1}));
    print STDOUT "A line on STDOUT!\n";
    print STDERR "A line on STDERR!\n";
    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 2}));

    exit 12;
});

my $pid2 = $one->run(sub {
    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 1}));
    print STDOUT "A line on STDOUT!\n";
    print STDERR "A line on STDERR!\n";
    $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));
    $Test2::Harness::STDERR_APIPE->write_message(encode_json({event_id => 2}));

    exit 0;
});

my $pid3 = $one->run(sub {
    my $pid = fork // die "Could not fork: $!";
    return $pid if $pid;

    sleep 30;

    exit 0;
});

my $pid4 = do {
    local $one->{merge_outputs} = 1;
    $one->run(sub {
        my $pid = fork // die "Could not fork: $!";
        return $pid if $pid;

        STDOUT->autoflush(1);
        STDERR->autoflush(1);

        $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 1, data => "First Event"}));
        print STDOUT "A line on STDOUT!\n";
        print STDERR "A line on STDERR!\n";
        $Test2::Harness::STDOUT_APIPE->write_message(encode_json({event_id => 2, data => "Second Event"}));

        die "ooops";
    });
};

$w->close();

waitpid($pid1, 0);
is($?, 0, "collector exited true");

waitpid($pid2, 0);
is($?, 0, "collector exited true");

kill('INT', $pid3);
waitpid($pid3, 0);
is($?, 0, "collector exited true");

waitpid($pid4, 0);
is($?, 0, "collector exited true");

my @got;
while (1) {
    my ($type, $val) = $r->get_line_burst_or_data;
    last unless $type;
    push @got => decode_json($val);
}

@got = sort { $a->{from_pid} <=> $b->{from_pid} || $a->{order} <=> $b->{order} || $a->{callback_stamp} <=> $b->{callback_stamp} } @got;

#use Data::Dumper;
#local $Data::Dumper::Sortkeys = 1;
#local $Data::Dumper::Trailingcomma = 1;
#local $Data::Dumper::Useqq = 1;
#local $Data::Dumper::Quotekeys = 0;
#
#print Dumper(\@got);

like(
    \@got,
    array {
        item {
            from_pid => $pid1,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for collector at}}]},
        };
        item {
            from_pid       => $pid1,
            process_launch => T(),
        };
        item {
            from_pid => $pid1,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for test job}}]},
        };
        item {
            from_pid => $pid1,
            stream   => "stdout",
            data     => {event_id => 1, data => "First Event"},
        };
        item {
            from_pid => $pid1,
            data     => {event_id => 1},
            stream   => "stderr",
        };
        item {
            from_pid => $pid1,
            line     => "A line on STDERR!\n",
            stream   => "stderr",
        };
        item {
            from_pid => $pid1,
            data     => {event_id => 2},
            stream   => "stderr",
        };
        item {
            from_pid => $pid1,
            line     => "A line on STDOUT!\n",
            stream   => "stdout",
        };
        item {
            from_pid => $pid1,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid     => $pid1,
            process_exit => {all => 3072, dmp => 0, err => 12, sig => 0},
        };



        item {
            from_pid => $pid2,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for collector}}]},
        };
        item {
            from_pid       => $pid2,
            process_launch => T(),
        };
        item {
            from_pid => $pid2,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for test job}}]}
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 1, data => "First Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 1},
            stream   => "stderr",
        };
        item {
            from_pid => $pid2,
            line     => "A line on STDERR!\n",
            stream   => "stderr",
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 2},
            stream   => "stderr",
        };
        item {
            from_pid => $pid2,
            line     => "A line on STDOUT!\n",
            stream   => "stdout",
        };
        item {
            from_pid => $pid2,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid     => $pid2,
            process_exit => {all => 0, dmp => 0, err => 0, sig => 0},
        };



        item {
            from_pid => $pid3,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for collector}}]},
        };
        item {
            from_pid       => $pid3,
            process_launch => T(),
        };
        item {
            from_pid => $pid3,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for test job}}]},
        };
        item {
            from_pid => $pid3,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{\Q$pid3\E: Got SIGINT, forwarding to child process}}]},
        };
        item {
            from_pid     => $pid3,
            process_exit => {all => 2, dmp => 0, err => 0, sig => 2},
        };



        item {
            from_pid => $pid4,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for collector}}]},
        };
        item {
            from_pid       => $pid4,
            process_launch => T(),
        };
        item {
            from_pid => $pid4,
            facets   => {info => [{tag => "WARNING", debug => 1, details => qr{Add IPC process control for test job}}]},
        };
        item {
            from_pid => $pid4,
            data     => {event_id => 1, data => "First Event"},
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            line     => "A line on STDOUT!\n",
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            line     => "A line on STDERR!\n",
            stream   => "stdout",
        };
        item {
            from_pid => $pid4,
            data     => {event_id => 2, data => "Second Event"},
            stream   => "stdout",
        };
        item {
            from_pid     => $pid4,
            process_exit => {all => 65280, dmp => 0, err => 255, sig => 0},
        };
        item {
            from_pid => not_in_set($pid1, $pid2, $pid3, $pid4, $$), # We do not know the child PID, but we know it is not these.
            facets   => {errors => [{tag => "ERROR", details => qr{ooops at t/unit/Test2/Harness/Util/Collector\.t}, fail => 1,}]},
        };

        end();
    },
    "Got all expected items"
);

done_testing;
