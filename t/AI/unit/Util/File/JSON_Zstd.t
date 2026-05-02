use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::JSON::Zstd;

my $tmp = tempdir(CLEANUP => 1);

subtest 'write/read round-trip' => sub {
    my $path = "$tmp/snap.json.zst";
    my $f = Test2::Harness2::Util::File::JSON::Zstd->new(name => $path);

    my $data = { run_id => 'abc', pending => [1, 2, 3], done => {} };
    $f->write($data);
    ok(-f $path, "file exists");

    my $f2 = Test2::Harness2::Util::File::JSON::Zstd->new(name => $path);
    is($f2->read, $data, "round-trip");
};

subtest 'maybe_read returns undef for missing file' => sub {
    my $f = Test2::Harness2::Util::File::JSON::Zstd->new(
        name => "$tmp/does_not_exist.json.zst",
    );
    is($f->maybe_read, undef, "missing file -> undef");
};

done_testing;
