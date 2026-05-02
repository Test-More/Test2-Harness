use Test2::V0;
use File::Temp qw/tempfile/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use Test2::Harness2::Collector::Logger::JSON;

my $class = 'Test2::Harness2::Collector::Logger::JSON';

is($class->update_type,           'replace', 'update_type is replace');
is($class->records_state,          1,         'records state');
is($class->records_general_events, 0,         'does not record general events');

subtest 'log_reader + fetch_state reads a snapshot' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    write_json_file_atomic($path, {hello => 'world'});

    my $r = $class->log_reader($path);
    ok($class->ready($r), 'ready returns true on fresh file');

    my $state = $class->fetch_state($r);
    is($state, {hello => 'world'}, 'fetched snapshot');

    ok(!$class->ready($r), 'ready false after fetch (mtime unchanged)');
};

subtest 'ready flips to true when file is rewritten' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    write_json_file_atomic($path, {v => 1});

    my $r = $class->log_reader($path);
    $class->fetch_state($r);
    ok(!$class->ready($r), 'not ready immediately after fetch');

    # Ensure a distinct mtime by sleeping just past the filesystem's
    # resolution. Most filesystems expose whole-second granularity via
    # stat(), so sub-second sleeps are not reliable here.
    sleep 1;
    write_json_file_atomic($path, {v => 2});

    ok($class->ready($r), 'ready after rewrite');
    my $state = $class->fetch_state($r);
    is($state, {v => 2}, 'snapshot reflects new content');
};

subtest 'ready false for missing file' => sub {
    my $r = $class->log_reader('/tmp/does-not-exist-json');
    ok(!$class->ready($r), 'ready false when file is missing');
    is($class->fetch_state($r), undef, 'fetch_state undef for missing file');
};

done_testing;
