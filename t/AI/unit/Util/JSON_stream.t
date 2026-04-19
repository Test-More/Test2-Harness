use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::JSON qw/stream_json_l stream_json_l_file encode_json/;

subtest 'stream_json_l_file on a .jsonl file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/events.jsonl";

    open(my $wh, '>', $path) or die $!;
    print $wh encode_json({n => $_}), "\n" for 1 .. 3;
    close($wh);

    my @seen;
    stream_json_l_file($path, sub { push @seen => $_[0] });
    is(\@seen, [{n => 1}, {n => 2}, {n => 3}], 'handler called per line');
};

subtest 'stream_json_l_file on a .json file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/one.json";

    open(my $wh, '>', $path) or die $!;
    print $wh encode_json({top => 'level'});
    close($wh);

    my @seen;
    stream_json_l_file($path, sub { push @seen => $_[0] });
    is(\@seen, [{top => 'level'}], 'whole-file .json yields one record');
};

subtest 'stream_json_l dispatches to _file for a local path' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/dispatch.jsonl";

    open(my $wh, '>', $path) or die $!;
    print $wh encode_json({x => 1}), "\n", encode_json({x => 2}), "\n";
    close($wh);

    my @seen;
    stream_json_l($path, sub { push @seen => $_[0] });
    is(\@seen, [{x => 1}, {x => 2}], 'stream_json_l iterates JSONL via _file');
};

subtest 'stream_json_l rejects a path that is neither a file nor a URL' => sub {
    like(
        dies { stream_json_l('/definitely/not/a/real/path/here', sub {}) },
        qr/is not a valid path/,
        'dies with a clear diagnostic'
    );
};

subtest 'stream_json_l_file rejects an unknown extension' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/data.txt";
    open(my $wh, '>', $path) or die $!;
    print $wh "nope\n";
    close($wh);

    like(
        dies { stream_json_l_file($path, sub {}) },
        qr/\.json or \.jsonl extension/,
        'clear diagnostic on wrong extension'
    );
};

done_testing;
