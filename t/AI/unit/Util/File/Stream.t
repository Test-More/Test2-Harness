use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::Stream;

subtest 'tail attribute seeks near the end on construction' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/big.log";

    open(my $wh, '>', $path) or die $!;
    print $wh "$_\n" for 1 .. 10;
    close($wh);

    my $tail2 = Test2::Harness2::Util::File::Stream->new(name => $path, tail => 2);
    is([$tail2->poll], ["9\n", "10\n"], 'tail=2 yields the last two lines');
};

subtest 'tail greater than file length starts at position 0' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/short.log";

    open(my $wh, '>', $path) or die $!;
    print $wh "$_\n" for 1 .. 3;
    close($wh);

    my $tail99 = Test2::Harness2::Util::File::Stream->new(name => $path, tail => 99);
    is([$tail99->poll], ["1\n", "2\n", "3\n"], 'short file: tail returns everything');
};

subtest 'poll_with_index exposes byte offsets' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/offsets.log";

    my $f = Test2::Harness2::Util::File::Stream->new(name => $path);
    $f->write("abc\n");
    $f->write("defg\n");

    my @rows = $f->poll_with_index;
    is(scalar @rows, 2, 'two rows');
    is($rows[0][0], 0, 'first row starts at 0');
    is($rows[0][1], 4, 'first row ends at 4 (after "abc\n")');
    is($rows[0][2], "abc\n", 'first row decoded line');
    is($rows[1][0], 4, 'second row starts at 4');
    is($rows[1][2], "defg\n", 'second row decoded line');
};

subtest 'use_write_lock serialises writes' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/locked.log";

    my $f = Test2::Harness2::Util::File::Stream->new(name => $path, use_write_lock => 1);
    $f->write("one\n");
    $f->write("two\n");

    open(my $rh, '<', $path) or die $!;
    is([<$rh>], ["one\n", "two\n"], 'locked writes land in order');
    close($rh);
};

done_testing;
