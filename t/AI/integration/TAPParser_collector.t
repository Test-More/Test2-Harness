use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @events;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

# A child emitting raw TAP (no Stream2), parsed by the pluggable TAPParser.
my $dir = tempdir(CLEANUP => 1);
my $ef  = "$dir/events.jsonl.zst";

my $tap = qq{TAP version 13\n1..2\nok 1 - alpha\nnot ok 2 - beta\n};

my $exit = Test2::Harness2::Collector->start(
    name         => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
    parser       => 'Test2::Harness2::Collector::Parser::TAPParser',
    exec_command => [$^X, '-e', "print q{$tap}; print STDERR qq{# a diagnostic\\n};"],
);

is($exit, 0, "collector returned 0");

my @events  = read_events($ef);
my @asserts = grep { $_->{facet_data}{assert} } @events;

is(scalar(@asserts),                         2,       "two assertions parsed from TAP");
is($asserts[0]{facet_data}{assert}{details}, 'alpha', "first assert details");
ok($asserts[0]{facet_data}{assert}{pass},  "first assert passed");
ok(!$asserts[1]{facet_data}{assert}{pass}, "second assert failed");

ok((grep { $_->{facet_data}{plan} } @events), "plan parsed");
ok(
    (grep { ($_->{facet_data}{info}[0]{tag} // '') eq 'DIAG' } @events),
    "stderr comment parsed as DIAG",
);

done_testing;
