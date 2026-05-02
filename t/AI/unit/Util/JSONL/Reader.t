use Test2::V0;
use File::Temp qw/tempfile/;

use Test2::Harness2::Util::JSONL::Reader;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

my $CLASS = 'Test2::Harness2::Util::JSONL::Reader';

subtest 'plain JSONL: read_lines drains and tails' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 1);
    print $fh qq[{"a":1}\n{"b":2}\n];
    close $fh;

    my $r = $CLASS->new(path => $path);
    is([$r->read_lines], [{a => 1}, {b => 2}], 'first read drains both items');
    is([$r->read_lines], [], 'second read drains nothing');

    open my $w, '>>', $path or die $!;
    $w->autoflush(1);
    print $w qq[{"c":3}\n];
    close $w;

    is([$r->read_lines], [{c => 3}], 'append surfaces on next read');
};

subtest 'plain JSONL: torn line held back until the writer finishes' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 1);
    close $fh;

    open my $w, '>>', $path or die $!;
    $w->autoflush(1);
    print $w qq[{"x":1}\n];
    print $w qq[{"y":2];    # no newline yet
    close $w;

    my $r = $CLASS->new(path => $path);
    is([$r->read_lines], [{x => 1}], 'torn line held back');

    open my $w2, '>>', $path or die $!;
    $w2->autoflush(1);
    print $w2 qq[}\n];
    close $w2;

    is([$r->read_lines], [{y => 2}], 'completed line surfaces');
};

subtest 'plain JSONL: readline returns one item at a time' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 1);
    print $fh qq[{"a":1}\n{"b":2}\n];
    close $fh;

    my $r = $CLASS->new(path => $path);
    is($r->readline, {a => 1}, 'first readline');
    is($r->readline, {b => 2}, 'second readline');
    is($r->readline, undef, 'third readline returns undef');
};

subtest 'zstd JSONL: read_lines drains and tails' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl.zst', UNLINK => 1);
    close $fh;
    unlink $path;

    my $w = open_zstd_writer($path);
    $w->print(qq[{"a":1}]);
    $w->print(qq[{"b":2}]);
    $w->close;

    my $r = $CLASS->new(path => $path);
    is([$r->read_lines], [{a => 1}, {b => 2}], 'zstd: drains both frames');
    is([$r->read_lines], [], 'zstd: empty after drain');

    my $w2 = open_zstd_writer($path);
    $w2->print(qq[{"c":3}]);
    $w2->close;

    is([$r->read_lines], [{c => 3}], 'zstd: append surfaces on next read');
};

subtest 'exists() reflects the underlying path' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.jsonl', UNLINK => 0);
    close $fh;
    my $r = $CLASS->new(path => $path);
    ok($r->exists, 'exists is true while file is present');

    unlink $path;
    ok(!$r->exists, 'exists is false after unlink');
};

done_testing;
