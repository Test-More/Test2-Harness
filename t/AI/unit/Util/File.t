use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::File;

subtest 'write is atomic + rewrite is plain overwrite' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/file.txt";

    my $f = Test2::Harness2::Util::File->new(name => $path);
    $f->write("first\n");
    is($f->read, "first\n", 'write stored content');

    # Atomic write must not leave a .pend residue on success.
    opendir(my $dh, $dir) or die $!;
    my @entries = sort grep { !/^\./ } readdir $dh;
    closedir $dh;
    is(\@entries, ['file.txt'], 'no .pend residue after atomic write');

    $f->rewrite("second");
    is($f->read, 'second', 'rewrite replaces content in place');
};

subtest 'read_line peek option does not advance cursor' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/log.txt";

    open(my $wh, '>', $path) or die $!;
    print $wh "a\nb\nc\n";
    close($wh);

    my $f = Test2::Harness2::Util::File->new(name => $path);
    is($f->read_line(peek => 1), "a\n", 'peek returns first line');
    is($f->read_line(peek => 1), "a\n", 'peek again returns the same first line');
    is($f->read_line,            "a\n", 'normal read returns first line and advances');
    is($f->read_line,            "b\n", 'next normal read returns second line');
};

subtest 'skip_bad_decode tolerates decode errors on a line' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/bad.txt";

    open(my $wh, '>', $path) or die $!;
    print $wh "line1\nline2\n";
    close($wh);

    my $f = Test2::Harness2::Util::File->new(
        name             => $path,
        skip_bad_decode  => 1,
    );

    # Force decode() to fail on every call.
    no warnings 'redefine';
    local *Test2::Harness2::Util::File::decode = sub { die "nope\n" };

    is($f->read_line, undef, 'skip_bad_decode drops the bad line');
};

done_testing;
