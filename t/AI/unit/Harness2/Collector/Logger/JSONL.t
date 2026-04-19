use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Collector::Logger::JSONL;

my $CLASS = 'Test2::Harness2::Collector::Logger::JSONL';

subtest 'metadata reports jsonl_file for file-backed logger' => sub {
    my $logger = $CLASS->new(
        ipcm_info   => {fake => 1},
        output_file => '/tmp/abs-events.jsonl',
    );
    is($logger->metadata, {jsonl_file => '/tmp/abs-events.jsonl'},
        'metadata carries the configured jsonl_file path');
};

subtest 'metadata for caller-supplied filehandle reports fileno+pid' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    my $logger = $CLASS->new(
        ipcm_info => {fake => 1},
        fh        => $fh,
    );
    my $meta = $logger->metadata;
    is(ref($meta), 'HASH', 'metadata is a hashref');
    is($meta->{jsonl_fileno}, fileno($fh), 'fileno matches the supplied handle');
    is($meta->{pid},          $$,          'pid matches the current process');
    ok(!exists $meta->{jsonl_file},
        'no jsonl_file when caller supplied a bare filehandle');
};

done_testing;
