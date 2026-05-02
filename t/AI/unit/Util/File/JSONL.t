use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::JSONL;

subtest 'write + read round-trip' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/log.jsonl";

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    $f->write({a => 1}, {b => 2}, {c => 3});

    open my $rh, '<', $path or die $!;
    is(
        [<$rh>],
        [qq[{"a":1}\n], qq[{"b":2}\n], qq[{"c":3}\n]],
        'each item is one JSON line on disk',
    );
    close $rh;

    is(
        [$f->read],
        [{a => 1}, {b => 2}, {c => 3}],
        'read returns every decoded line',
    );
};

subtest 'rewrite replaces in place' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/log.jsonl";

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    $f->write({first => 1});
    is([$f->read], [{first => 1}], 'first write present');

    $f->rewrite({second => 2}, {third => 3});
    is(
        [$f->read],
        [{second => 2}, {third => 3}],
        'rewrite replaces every line',
    );
};

subtest 'read on a missing file returns empty list' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/missing.jsonl";

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    is([$f->read], [], 'empty list for missing file');
};

subtest 'read skips empty lines' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/sparse.jsonl";

    open my $wh, '>', $path or die $!;
    print $wh qq[{"a":1}\n\n{"b":2}\n];
    close $wh;

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    is([$f->read], [{a => 1}, {b => 2}], 'empty lines ignored');
};

subtest 'read_line decodes a single line' => sub {
    my $f = Test2::Harness2::Util::File::JSONL->new(name => '/dev/null');
    is($f->read_line(qq[{"x":42}\n]), {x => 42}, 'decodes raw line');
};

done_testing;
