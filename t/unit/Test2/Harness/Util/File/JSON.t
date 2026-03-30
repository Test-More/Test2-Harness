use Test2::V0 -target => 'Test2::Harness::Util::File::JSON';

use File::Temp qw/tempdir/;
use File::Spec;

subtest 'round-trip JSON read/write' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'data.json');

    my $f = CLASS->new(name => $path);
    my $data = {key => 'value', num => 42, list => [1, 2, 3]};

    $f->write($data);
    ok(-e $path, "file created after write");

    my $result = $f->read;
    is($result, $data, "round-trip through JSON file");
};

subtest 'maybe_read returns undef for missing file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'missing.json');

    my $f = CLASS->new(name => $path);
    is($f->maybe_read, undef, "returns undef for missing file");
};

subtest 'maybe_read returns undef for empty file' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'empty.json');

    open my $fh, '>', $path or die $!;
    close $fh;

    my $f = CLASS->new(name => $path);
    is($f->maybe_read, undef, "returns undef for empty file");
};

subtest 'line reading is disabled' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'data.json');

    my $f = CLASS->new(name => $path);
    like(dies { $f->read_line }, qr/line reading is disabled/, "read_line dies");
    like(dies { $f->reset },     qr/line reading is disabled/, "reset dies");
};

subtest 'pretty printing' => sub {
    my $dir   = tempdir(CLEANUP => 1);
    my $path  = File::Spec->catfile($dir, 'pretty.json');
    my $pathp = File::Spec->catfile($dir, 'ugly.json');

    my $fp = CLASS->new(name => $path,  pretty => 1);
    my $fu = CLASS->new(name => $pathp, pretty => 0);

    my $data = {a => 1};
    $fp->write($data);
    $fu->write($data);

    my $pretty_content = do { local $/; open(my $fh,'<',$path) or die $!; <$fh> };
    my $ugly_content   = do { local $/; open(my $fh,'<',$pathp) or die $!; <$fh> };

    like($pretty_content, qr/\n/, "pretty output has newlines");
    unlike($ugly_content, qr/\n/, "compact output has no newlines");
};

done_testing;
