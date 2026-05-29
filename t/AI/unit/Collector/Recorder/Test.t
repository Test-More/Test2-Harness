use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Event;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2::Collector::Recorder::Test;

# The test recorder extends the base recorder. It routes state-transition
# events to a transitions file and the final-state event to a state file,
# leaving everything else in the events file. It also touches the touchfile
# on every transition (the base only touches on finalize).

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

sub event_ev   ($tag)   { return Test2::Harness2::Event->new(facet_data => {info => [{tag => $tag}]}) }
sub trans_ev   ($state) { return Test2::Harness2::Event->new(facet_data => {harness_state_transition => {state => $state, stamp => 1}}) }
sub final_ev   ($pass)  { return Test2::Harness2::Event->new(facet_data => {harness_final_state => {pass => $pass, fail_count => $pass ? 0 : 1}}) }

sub new_recorder (%extra) {
    my $id = $n++;
    return Test2::Harness2::Collector::Recorder::Test->new(
        events_file      => "$tmp/$id-events.jsonl.zst",
        transitions_file => "$tmp/$id-transitions.jsonl.zst",
        state_file       => "$tmp/$id-state.jsonl.zst",
        %extra,
    );
}

subtest does_role => sub {
    ok(
        Test2::Harness2::Collector::Recorder::Test->DOES('Test2::Harness2::Collector::Role::Recorder'),
        "test recorder consumes the Recorder role (via the base)",
    );
};

subtest requires_extra_files => sub {
    my $err = dies {
        Test2::Harness2::Collector::Recorder::Test->new(events_file => "$tmp/x.jsonl.zst");
    };
    like($err, qr/transitions_file|state_file/, "transitions_file/state_file required");
};

subtest routes_events_by_facet => sub {
    my $rec = new_recorder();

    $rec->record_event(event_ev('A'));
    $rec->record_event(trans_ev('starting'));
    $rec->record_event(event_ev('B'));
    $rec->record_event(trans_ev('failing'));
    $rec->record_event(final_ev(0));
    $rec->finalize;

    my $events = read_jsonl_zst($rec->events_file);
    my $trans  = read_jsonl_zst($rec->transitions_file);
    my $state  = read_jsonl_zst($rec->state_file);

    is(scalar(@$events), 2, "two plain events in the events file");
    is([map { $_->{facet_data}{info}[0]{tag} } @$events], ['A', 'B'], "only the info events landed in events file");

    is(scalar(@$trans), 2, "two transitions in the transitions file");
    is([map { $_->{facet_data}{harness_state_transition}{state} } @$trans], ['starting', 'failing'], "transitions captured in order");

    is(scalar(@$state), 1, "one final-state row in the state file");
    is($state->[0]{facet_data}{harness_final_state}{pass}, 0, "final state recorded");
};

subtest touches_touchfile_on_transition => sub {
    my $touch = "$tmp/transition-touch";
    my $rec   = new_recorder(touchfile => $touch);

    ok(!-e $touch, "touchfile absent initially");
    $rec->record_event(trans_ev('starting'));
    ok(-e $touch, "touchfile created on the first transition");

    $rec->finalize;
};

done_testing;
