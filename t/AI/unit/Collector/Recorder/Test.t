use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use IO::Select;

use Test2::Harness2::Event;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2::Collector::Recorder::Test;

# The test recorder extends the base recorder. It sends state transitions and
# the final state to the transition sockets (these are no longer written to any
# file), and leaves everything else in the events file.

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

# Accept the recorder's connection and return the decoded transition payloads
# (the {type,payload} envelopes' payloads) it wrote.
sub drain ($conn) {
    $conn->blocking(0);
    my $fb  = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $sel = IO::Select->new($conn);
    while ($sel->can_read(2)) {
        my $buf = '';
        my $bytes = sysread($conn, $buf, 65536);
        last unless $bytes;
        $fb->push_bytes($buf);
    }
    return [map { decode_json($_->{payload})->{payload} } $fb->drain];
}

sub event_ev ($tag)   { return Test2::Harness2::Event->new(facet_data => {info                     => [{tag => $tag}]}) }
sub trans_ev ($state) { return Test2::Harness2::Event->new(facet_data => {harness_state_transition => {state => $state, stamp      => 1}}) }
sub final_ev ($pass)  { return Test2::Harness2::Event->new(facet_data => {harness_final_state      => {pass  => $pass,  fail_count => $pass ? 0 : 1}}) }

sub new_recorder (%extra) {
    my $id = $n++;
    return Test2::Harness2::Collector::Recorder::Test->new(
        events_file => "$tmp/$id-events.jsonl.zst",
        %extra,
    );
}

subtest does_role => sub {
    ok(
        Test2::Harness2::Collector::Recorder::Test->DOES('Test2::Harness2::Collector::Role::Recorder'),
        "test recorder consumes the Recorder role (via the base)",
    );
};

subtest routes_events_by_facet => sub {
    my $path   = "$tmp/$n-transitions.sock";
    my $listen = open_unix_listen($path);
    my $rec    = new_recorder(transition_sockets => [$path]);
    my $conn   = $listen->accept;    # recorder connected at construction
    $rec->set_collector_info(uuid => 'UUID-9', name => 'some/test.t', try => 1);

    $rec->record_event(event_ev('A'));
    $rec->record_event(trans_ev('starting'));
    $rec->record_event(event_ev('B'));
    $rec->record_event(trans_ev('failing'));
    $rec->record_event(final_ev(0));
    $rec->finalize;

    my $events = read_jsonl_zst($rec->events_file);

    is(scalar(@$events),                                  2,          "only the two plain events landed in the events file");
    is([map { $_->{facet_data}{info}[0]{tag} } @$events], ['A', 'B'], "plain events kept; transitions/state routed away");

    # The socket sees the transitions, the final state, and the finalization.
    my $msgs   = drain($conn);
    my @states = map { $_->{facet_data}{harness_state_transition}{state} }
        grep { $_->{facet_data}{harness_state_transition} } @$msgs;
    is(\@states, ['starting', 'failing'], "transitions delivered on the socket in order");

    my ($final) = grep { $_->{facet_data}{harness_final_state} } @$msgs;
    ok($final, "final state delivered on the socket");
    is($final->{facet_data}{harness_final_state}{pass}, 0, "final state carries the verdict");
    ok((grep { $_->{facet_data}{harness_collector_finalized} } @$msgs), "finalization delivered on the socket");

    # Every message carries the collector uuid.
    ok((!grep { ($_->{facet_data}{harness_collector}{uuid} // '') ne 'UUID-9' } @$msgs), "every message carries the collector uuid");

    # The starting message carries name, events file, and try.
    my ($start) = grep { ($_->{facet_data}{harness_state_transition}{state} // '') eq 'starting' } @$msgs;
    my $shc = $start->{facet_data}{harness_collector};
    is($shc->{name}, 'some/test.t', "start message carries the collector name");
    is($shc->{try},  1,             "start message carries the try number");
    ok($shc->{events_file}, "start message carries the events file path");

    # Identity is sent once (the start message); later messages carry only the
    # uuid. The final-state message does not repeat name / try / events_file.
    my $fhc = $final->{facet_data}{harness_collector};
    is($fhc->{uuid}, 'UUID-9', "final message carries the uuid");
    ok(!exists $fhc->{name},        "final message omits the name");
    ok(!exists $fhc->{try},         "final message omits the try");
    ok(!exists $fhc->{events_file}, "final message omits the events file path");

    # A plain transition carries only the uuid too.
    my ($failing) = grep { ($_->{facet_data}{harness_state_transition}{state} // '') eq 'failing' } @$msgs;
    ok(!exists $failing->{facet_data}{harness_collector}{name}, "non-start transition omits name");
};

subtest no_transitions_file => sub {
    my $rec = new_recorder();
    $rec->record_event(trans_ev('starting'));
    $rec->finalize;

    ok(!-e "$tmp/transitions.jsonl.zst", "no transitions file is created");
};

done_testing;
