use Test2::V0 -target => 'Test2::Harness::Util::File::JSONL';

use File::Temp qw/tempdir/;
use File::Spec;

subtest 'write and poll JSON objects' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'data.jsonl');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $jsonl = CLASS->new(name => $path);

    my @items = ({a => 1}, {b => 2}, {c => [1, 2, 3]});
    $jsonl->write(@items);

    my @result = $jsonl->poll;
    is(\@result, \@items, "round-trip JSONL write/poll");
};

subtest 'incremental poll' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'incr.jsonl');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $jsonl = CLASS->new(name => $path);

    $jsonl->write({step => 1});
    my @batch1 = $jsonl->poll;
    is(\@batch1, [{step => 1}], "first batch");

    $jsonl->write({step => 2});
    my @batch2 = $jsonl->poll;
    is(\@batch2, [{step => 2}], "second batch only returns new item");
};

subtest 'encode appends newline' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'nl.jsonl');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $jsonl = CLASS->new(name => $path);
    my $encoded = $jsonl->encode({x => 1});
    like($encoded, qr/\n$/, "encoded line ends with newline");
};

subtest 'read returns all items from start' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'all.jsonl');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $jsonl = CLASS->new(name => $path);
    $jsonl->write({n => 1}, {n => 2}, {n => 3});

    my @all = $jsonl->read;
    is(\@all, [{n => 1}, {n => 2}, {n => 3}], "read returns all items");
};

done_testing;
