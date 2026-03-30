use Test2::V0 -target => 'Test2::Harness::Util::File::Stream';

use File::Temp qw/tempdir/;
use File::Spec;

subtest 'write and poll' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'stream.txt');

    # Create the file first so Stream can open it
    open my $fh, '>', $path or die $!;
    close $fh;

    my $stream = CLASS->new(name => $path);

    $stream->write("line one\n", "line two\n");

    my @lines = $stream->poll;
    is(\@lines, ["line one\n", "line two\n"], "poll returns written lines");
};

subtest 'poll is incremental' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'incr.txt');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $stream = CLASS->new(name => $path);

    $stream->write("first\n");
    my @batch1 = $stream->poll;
    is(\@batch1, ["first\n"], "first poll returns first line");

    $stream->write("second\n");
    my @batch2 = $stream->poll;
    is(\@batch2, ["second\n"], "second poll returns only new line");
};

subtest 'read returns all lines from beginning' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'read.txt');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $stream = CLASS->new(name => $path);
    $stream->write("a\n", "b\n", "c\n");

    my @all = $stream->read;
    is(\@all, ["a\n", "b\n", "c\n"], "read returns all lines");

    # read always starts from position 0
    my @again = $stream->read;
    is(\@again, ["a\n", "b\n", "c\n"], "read returns same lines again");
};

subtest 'poll with max limit' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'maxpoll.txt');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $stream = CLASS->new(name => $path);
    $stream->write("x\n", "y\n", "z\n");

    my @limited = $stream->poll(max => 2);
    is(scalar @limited, 2, "poll with max => 2 returns 2 lines");
};

subtest 'poll_with_index returns positions' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'index.txt');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $stream = CLASS->new(name => $path);
    $stream->write("one\n");

    my @indexed = $stream->poll_with_index(from => 0);
    is(scalar @indexed, 1, "one entry in indexed output");
    is($indexed[0][2], "one\n", "line content at position [2]");
    ok(defined $indexed[0][0], "start position defined");
    ok(defined $indexed[0][1], "end position defined");
};

done_testing;
