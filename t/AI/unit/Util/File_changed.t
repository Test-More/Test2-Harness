use Test2::V0;
use File::Temp qw/tempfile/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use Test2::Harness2::Util::File;
use Test2::Harness2::Util::File::JSON;

subtest 'changed()' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;

    my $f = Test2::Harness2::Util::File->new(name => $path);

    ok($f->changed, 'first changed() is true (no prior state)');
    $f->_record_state;
    ok(!$f->changed, 'not changed immediately after record_state');

    # A content change in a new inode (atomic-swap pattern) must be
    # detected even if the filesystem collapses both mtimes into the
    # same one-second bucket.
    my $tmp = "$path.tmp";
    open my $w, '>', $tmp or die $!;
    print $w "x"; close $w;
    rename $tmp, $path or die $!;

    ok($f->changed, 'atomic rename-in-place detected');
    $f->_record_state;
    ok(!$f->changed, 'not changed after recording new state');
};

subtest 'read_if_changed returns empty list when nothing changed' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    write_json_file_atomic($path, {hello => 'world'});

    my $j = Test2::Harness2::Util::File::JSON->new(name => $path);

    my @first = $j->read_if_changed;
    is(scalar(@first), 1, 'first read returns one element');
    is($first[0], {hello => 'world'}, 'payload preserved');

    my @second = $j->read_if_changed;
    is(scalar(@second), 0, 'unchanged file returns empty list');
};

subtest 'read_if_changed returns (undef) for literal JSON null' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print $fh "null\n";
    close $fh;

    my $j = Test2::Harness2::Util::File::JSON->new(name => $path);

    my @r = $j->read_if_changed;
    is(scalar(@r), 1, '(undef) is one element, not empty list');
    ok(!defined $r[0], 'element is undef because the JSON was null');

    my @again = $j->read_if_changed;
    is(scalar(@again), 0, 'no re-read after the null was recorded');
};

subtest 'read_if_changed (undef) for empty file, then distinguishes a real write' => sub {
    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    # Empty file on disk
    open my $w, '>', $path or die $!;
    close $w;

    my $j = Test2::Harness2::Util::File::JSON->new(name => $path);

    my @r = $j->read_if_changed;
    is(scalar(@r), 1, '(undef) returned for empty file');
    ok(!defined $r[0], 'empty file reports undef content');

    # Replace with real JSON; size change must be noticed even if
    # mtime resolution didn't move.
    write_json_file_atomic($path, {v => 2});
    my @next = $j->read_if_changed;
    is(scalar(@next), 1, 'new content produces a read');
    is($next[0], {v => 2}, 'new payload surfaced');
};

done_testing;
