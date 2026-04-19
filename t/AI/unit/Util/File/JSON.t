use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File::JSON;

subtest 'write + read roundtrip' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/data.json";

    my $f = Test2::Harness2::Util::File::JSON->new(name => $path);
    $f->write({run_id => 'R1', counts => [1, 2, 3]});

    my $loaded = $f->read;
    is($loaded, {run_id => 'R1', counts => [1, 2, 3]}, 'roundtrip through write + read');
};

subtest 'maybe_read returns undef for missing or empty file' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $missing = Test2::Harness2::Util::File::JSON->new(name => "$dir/nope.json");
    is($missing->maybe_read, undef, 'missing file: undef');

    my $empty_path = "$dir/empty.json";
    open(my $fh, '>', $empty_path) or die $!;
    close($fh);

    my $empty = Test2::Harness2::Util::File::JSON->new(name => $empty_path);
    is($empty->maybe_read, undef, 'zero-byte file: undef');
};

subtest 'pretty attribute switches encoder' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $compact = Test2::Harness2::Util::File::JSON->new(name => "$dir/a.json");
    my $pretty  = Test2::Harness2::Util::File::JSON->new(name => "$dir/b.json", pretty => 1);

    $compact->write({a => 1, b => 2});
    $pretty->write({a  => 1, b => 2});

    my $a = do { open(my $fh, '<', "$dir/a.json") or die $!; local $/; <$fh> };
    my $b = do { open(my $fh, '<', "$dir/b.json") or die $!; local $/; <$fh> };

    unlike($a, qr/\n/, 'compact encoder has no newline');
    like($b,   qr/\n/, 'pretty encoder inserts newlines');
};

done_testing;
