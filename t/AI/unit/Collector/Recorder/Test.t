use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Atomic::Pipe;

use Test2::Harness2::Event;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2::Collector::Recorder::Test;

# The test recorder extends the base recorder. It writes the final-state event
# to a state file, sends state transitions and the final state to the
# notification pipes (transitions are no longer written to any file), and
# leaves everything else in the events file.

my $tmp = tempdir(CLEANUP => 1);
my $n   = 0;

sub read_jsonl_zst ($path) {
    return [] unless -e $path;
    my $r = open_zstd_reader($path);
    my @out;
    while (defined(my $line = $r->readline)) {
        chomp $line;
        next unless length $line;
        push @out => decode_json($line);
    }
    return \@out;
}

# Drain every message currently available on a pipe read-end.
sub drain ($pipe) {
    $pipe->blocking(0);    # read_message returns undef once drained
    my @out;
    while (defined(my $msg = $pipe->read_message)) {
        push @out => decode_json($msg);
    }
    return \@out;
}

sub event_ev ($tag)   { return Test2::Harness2::Event->new(facet_data => {info => [{tag => $tag}]}) }
sub trans_ev ($state) { return Test2::Harness2::Event->new(facet_data => {harness_state_transition => {state => $state, stamp => 1}}) }
sub final_ev ($pass)  { return Test2::Harness2::Event->new(facet_data => {harness_final_state => {pass => $pass, fail_count => $pass ? 0 : 1}}) }

sub new_recorder (%extra) {
    my $id = $n++;
    return Test2::Harness2::Collector::Recorder::Test->new(
        events_file => "$tmp/$id-events.jsonl.zst",
        state_file  => "$tmp/$id-state.jsonl.zst",
        %extra,
    );
}

subtest does_role => sub {
    ok(
        Test2::Harness2::Collector::Recorder::Test->DOES('Test2::Harness2::Collector::Role::Recorder'),
        "test recorder consumes the Recorder role (via the base)",
    );
};

subtest requires_state_file => sub {
    my $err = dies {
        Test2::Harness2::Collector::Recorder::Test->new(events_file => "$tmp/x.jsonl.zst");
    };
    like($err, qr/state_file/, "state_file required");
};

subtest routes_events_by_facet => sub {
    my ($r, $w) = Atomic::Pipe->pair(compression => 'zstd', keep_compressed => 1);
    my $rec = new_recorder(pipes => [$w]);

    $rec->record_event(event_ev('A'));
    $rec->record_event(trans_ev('starting'));
    $rec->record_event(event_ev('B'));
    $rec->record_event(trans_ev('failing'));
    $rec->record_event(final_ev(0));
    $rec->finalize;

    my $events = read_jsonl_zst($rec->events_file);
    my $state  = read_jsonl_zst($rec->state_file);

    is(scalar(@$events), 2, "only the two plain events landed in the events file");
    is([map { $_->{facet_data}{info}[0]{tag} } @$events], ['A', 'B'], "plain events kept; transitions/state routed away");

    is(scalar(@$state), 1, "one final-state row in the state file");
    is($state->[0]{facet_data}{harness_final_state}{pass}, 0, "final state recorded to file");

    # The pipe sees the transitions, the final state, and the finalization.
    my $msgs = drain($r);
    my @states = map { $_->{facet_data}{harness_state_transition}{state} }
        grep { $_->{facet_data}{harness_state_transition} } @$msgs;
    is(\@states, ['starting', 'failing'], "transitions delivered on the pipe in order");

    ok((grep { $_->{facet_data}{harness_final_state} } @$msgs), "final state delivered on the pipe");
    ok((grep { $_->{facet_data}{harness_collector_finalized} } @$msgs), "finalization delivered on the pipe");
};

subtest no_transitions_file => sub {
    my $rec = new_recorder();
    $rec->record_event(trans_ev('starting'));
    $rec->finalize;

    ok(!-e "$tmp/transitions.jsonl.zst", "no transitions file is created");
};

done_testing;
