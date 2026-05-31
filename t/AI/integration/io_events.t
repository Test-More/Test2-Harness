use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# End-to-end: run a job whose subtest prints to STDOUT/STDERR (and warns) under
# the collector, with the io_events feature on and off. With it on, those prints
# become info events folded into the subtest; with it off they land loose at the
# top level.

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @events;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

sub run_job (%opts) {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    Test2::Harness2::Collector->start(
        name         => "io-events", is_test => 1, run_uuid => "RUN",
        (exists $opts{io_events} ? (io_events => $opts{io_events}) : ()),
        processor    => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-Ilib', 't/AI/scripts/io_events_job.pl'],
    );

    return [read_events($ef)];
}

# All info details found inside an event tree (recursing into parent.children).
sub info_details ($facets, $out) {
    push @$out => map { $_->{details} // '' } @{$facets->{info}} if $facets->{info};
    info_details($_, $out) for @{$facets->{parent}{children} // []};
}

# Info details found ONLY inside the named top-level subtest.
sub subtest_info ($events, $name) {
    my ($st) = grep { ($_->{facet_data}{assert}{details} // '') eq $name && $_->{facet_data}{parent} } @$events;
    return () unless $st;
    my @out;
    info_details($st->{facet_data}, \@out);
    return @out;
}

# Top-level (not inside any subtest) raw stream lines.
sub top_stream_lines ($events) {
    return map { $_->{facet_data}{from_stream}{details} // '' }
        grep { $_->{facet_data}{from_stream} } @$events;
}

subtest on_by_default_folds_prints_into_subtest => sub {
    my $events = run_job();    # no io_events attr: on by default

    my @inside = subtest_info($events, 'outer');
    ok((grep { $_ eq "inside-stdout" } @inside), "STDOUT print folded into the subtest");
    ok((grep { $_ eq "inside-stderr" } @inside), "STDERR print folded into the subtest");
    ok((grep { $_ eq "inside-warn" }   @inside), "warning folded into the subtest");

    # The top-level print still arrives as a raw stream line, not converted.
    # (Raw stream lines are chomped by the collector.)
    ok((grep { $_ eq "top-stdout" } top_stream_lines($events)), "top-level print stays a raw stream line");
};

subtest disabled_via_attr_leaves_prints_loose => sub {
    my $events = run_job(io_events => 0);    # explicit off

    my @inside = subtest_info($events, 'outer');
    ok((!grep { $_ eq "inside-stdout" } @inside), "STDOUT print NOT folded when disabled");

    my @lines = top_stream_lines($events);
    ok((grep { $_ eq "inside-stdout" } @lines), "the inside print is a loose top-level stream line when disabled");
};

done_testing;
