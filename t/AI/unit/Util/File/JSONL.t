use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::JSONL;

subtest 'write + poll roundtrip of structured records' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/events.jsonl";

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    $f->write({type => 'start', id => 1});
    $f->write({type => 'ok',    id => 2});
    $f->write({type => 'done',  id => 3});

    my @records = $f->poll;
    is(\@records, [
        {type => 'start', id => 1},
        {type => 'ok',    id => 2},
        {type => 'done',  id => 3},
    ], 'all records decoded in order');

    is([$f->poll], [], 'subsequent poll returns nothing until more arrive');
};

subtest 'poll(max => N) caps returned records' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/events.jsonl";

    my $f = Test2::Harness2::Util::File::JSONL->new(name => $path);
    $f->write({n => $_}) for 1 .. 5;

    my @first = $f->poll(max => 2);
    is(\@first, [{n => 1}, {n => 2}], 'first two records');

    my @rest = $f->poll;
    is(\@rest, [{n => 3}, {n => 4}, {n => 5}], 'remaining records on next poll');
};

done_testing;
