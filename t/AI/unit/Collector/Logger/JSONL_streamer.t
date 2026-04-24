use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Collector::Logger::JSONL;

my $class = 'Test2::Harness2::Collector::Logger::JSONL';

is($class->update_style,           'append', 'update_style is append');
is($class->records_state,          0,        'does not record state');
is($class->records_general_events, 1,        'records general events');

subtest 'log_reader + fetch_events on a populated file' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 1);
    print $fh qq[{"event_id":"A","facet_data":{"info":[{"details":"one"}]}}\n];
    print $fh qq[{"event_id":"B","facet_data":{"info":[{"details":"two"}]}}\n];
    close $fh;

    my $r = $class->log_reader($path);
    ok($class->ready($r), 'ready returns true when file has content');

    my @events = $class->fetch_events($r);
    is(scalar(@events), 2, 'fetched both events');
    is($events[0]->{event_id}, 'A', 'first event preserved');
    is($events[1]->{event_id}, 'B', 'second event preserved');

    # After draining once, nothing new to fetch
    ok(!$class->ready($r), 'ready returns false after drain');
    is([$class->fetch_events($r)], [], 'fetch_events empty after drain');
};

subtest 'ready is false for a missing file' => sub {
    my $r = $class->log_reader('/tmp/does-not-exist-for-sure-jsonl');
    ok(!$class->ready($r), 'ready false on non-existent file');
};

subtest 'incremental appends are streamed' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 1);
    close $fh;

    my $r = $class->log_reader($path);

    open my $w, '>>', $path or die "open: $!";
    $w->autoflush(1);
    print $w qq[{"event_id":"one"}\n];
    close $w;

    my @first = $class->fetch_events($r);
    is(scalar(@first), 1, 'first append visible');

    open $w, '>>', $path or die "open: $!";
    $w->autoflush(1);
    print $w qq[{"event_id":"two"}\n];
    close $w;

    my @second = $class->fetch_events($r);
    is(scalar(@second), 1, 'second append visible');
    is($second[0]->{event_id}, 'two', 'no re-read of earlier lines');
};

done_testing;
