use Test2::V0 -target => 'Test2::Harness::Util::LogFile';

use File::Temp qw/tempdir/;
use File::Spec;
use Test2::Harness::Util::JSON qw/encode_json/;

subtest 'constructor requires a valid log file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'missing.jsonl');

    like(
        dies { CLASS->new(name => $path) },
        qr/not a valid log file|Could not open/,
        "dies for missing file"
    );
};

subtest 'poll returns events from log file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'events.jsonl');

    # Write two events to the log
    open my $fh, '>', $path or die $!;
    for my $i (1 .. 2) {
        print $fh encode_json({
            job_id     => 'j1',
            job_try    => 0,
            run_id     => 'r1',
            event_id   => "event-$i",
            stamp      => 12345,
            facet_data => {
                harness => {
                    job_id   => 'j1',
                    job_try  => 0,
                    run_id   => 'r1',
                    event_id => "event-$i",
                },
                trace => {stamp => 12345},
            },
        }), "\n";
    }
    close $fh;

    my $lf = CLASS->new(name => $path);
    my @events = $lf->poll;

    is(scalar @events, 2, "poll returns two events");
    isa_ok($events[0], 'Test2::Harness::Event');
    isa_ok($events[1], 'Test2::Harness::Event');
    is($events[0]->event_id, 'event-1', "first event id");
    is($events[1]->event_id, 'event-2', "second event id");
};

subtest 'poll handles partial lines via buffer' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'partial.jsonl');

    my $json = encode_json({
        job_id     => 'j2',
        job_try    => 0,
        run_id     => 'r2',
        event_id   => 'ev1',
        stamp      => 99999,
        facet_data => {
            harness => {job_id => 'j2', job_try => 0, run_id => 'r2', event_id => 'ev1'},
            trace   => {stamp => 99999},
        },
    });

    # Write without trailing newline first
    open my $fh, '>', $path or die $!;
    print $fh $json;
    close $fh;

    my $lf = CLASS->new(name => $path);
    my @events = $lf->poll;
    is(scalar @events, 0, "no events returned for partial line (no newline)");

    # Now complete the line
    open $fh, '>>', $path or die $!;
    print $fh "\n";
    close $fh;

    @events = $lf->poll;
    is(scalar @events, 1, "event returned after line completed");
};

subtest 'poll returns empty when no new data' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'empty.jsonl');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $lf = CLASS->new(name => $path);
    my @events = $lf->poll;
    is(scalar @events, 0, "empty poll on empty file");

    # Poll again with no changes
    @events = $lf->poll;
    is(scalar @events, 0, "still empty on second poll");
};

done_testing;
