use Test2::V0 -target => 'Test2::Harness::Util::File';

use File::Temp qw/tempdir/;
use File::Spec;

subtest 'constructor requires name' => sub {
    like(
        dies { CLASS->new() },
        qr/'name' is a required attribute/,
        "dies without name"
    );
};

subtest 'basic read and write' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'test.txt');

    my $f = CLASS->new(name => $path);
    is($f->name, $path, "name accessor");

    $f->write("hello\n");
    ok(-e $path, "file was created");

    my $content = $f->read;
    is($content, "hello\n", "read returns content");
};

subtest 'exists' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'exists.txt');

    my $f = CLASS->new(name => $path);
    ok(!$f->exists, "exists returns false for missing file");

    open my $fh, '>', $path or die $!;
    close $fh;
    ok($f->exists, "exists returns true after creation");
};

subtest 'maybe_read' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'maybe.txt');

    my $f = CLASS->new(name => $path);
    is($f->maybe_read, undef, "maybe_read returns undef for missing file");

    $f->write("content\n");
    is($f->maybe_read, "content\n", "maybe_read returns content when file exists");
};

subtest 'rewrite' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'rewrite.txt');

    my $f = CLASS->new(name => $path);
    $f->write("original\n");
    $f->rewrite("updated\n");
    is($f->read, "updated\n", "rewrite replaces content");
};

subtest 'read_line iteration' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'lines.txt');

    open my $fh, '>', $path or die $!;
    print $fh "line1\nline2\nline3\n";
    close $fh;

    my $f = CLASS->new(name => $path);

    # read_line uses non-blocking fh, mark done to allow partial lines
    $f->{done} = 1;

    my $line1 = $f->read_line;
    my $line2 = $f->read_line;
    my $line3 = $f->read_line;

    is($line1, "line1\n", "first line");
    is($line2, "line2\n", "second line");
    is($line3, "line3\n", "third line");
    is($f->read_line, undef, "returns undef at EOF");
};

subtest 'reset clears state' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'reset.txt');

    open my $fh, '>', $path or die $!;
    print $fh "lineA\nlineB\n";
    close $fh;

    my $f = CLASS->new(name => $path);
    $f->{done} = 1;

    my $first = $f->read_line;
    is($first, "lineA\n", "read first line");

    $f->reset;
    my $again = $f->read_line;
    is($again, "lineA\n", "after reset reads from beginning again");
};

done_testing;
