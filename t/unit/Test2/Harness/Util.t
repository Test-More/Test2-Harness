use Test2::V0 -target => 'Test2::Harness::Util';

use File::Temp qw/tempdir tempfile/;
use File::Spec;
use Cwd qw/realpath/;

BEGIN {
    CLASS()->import(qw/
        parse_exit
        mod2file
        file2mod
        clean_path
        find_in_updir
        is_same_file
        hash_purge
        read_file
        write_file
        write_file_atomic
        open_file
        maybe_read_file
        lock_file
        unlock_file
        hub_truth
    /);
}

# Backward-compat: looks_like_uuid was moved to Test2::Util::UUID in v2.x
# but old code (e.g., v1.x YathUI.pm installed in perldocker containers)
# still imports it from Test2::Harness::Util.
subtest 'looks_like_uuid backward-compat export' => sub {
    can_ok($CLASS, 'looks_like_uuid');

    # Verify it can be imported
    $CLASS->import('looks_like_uuid');
    ok(defined &looks_like_uuid, 'looks_like_uuid is importable from Test2::Harness::Util');

    # Verify it works correctly
    my $valid = 'A1B2C3D4-E5F6-7890-ABCD-EF1234567890';
    is(looks_like_uuid($valid), $valid, 'recognizes a valid UUID');
    ok(!looks_like_uuid(undef),      'rejects undef');
    ok(!looks_like_uuid('too-short'), 'rejects short strings');
    ok(!looks_like_uuid('not-a-uuid-at-all-but-has-36-chars!'), 'rejects non-hex 36-char strings');
};

subtest parse_exit => sub {
    my $r = parse_exit(0);
    is($r, {sig => 0, err => 0, dmp => 0, all => 0}, "zero exit");

    $r = parse_exit(256);  # exit code 1 shifted left by 8
    is($r, {sig => 0, err => 1, dmp => 0, all => 256}, "exit code 1");

    $r = parse_exit(9);  # signal 9
    is($r, {sig => 9, err => 0, dmp => 0, all => 9}, "signal 9");

    $r = parse_exit(11 | 128);  # signal 11 with core dump
    is($r, {sig => 11, err => 0, dmp => 128, all => 139}, "signal with core dump");

    like(dies { parse_exit() }, qr/exit value is required/, "dies without arg");
};

subtest mod2file => sub {
    is(mod2file('Foo::Bar'), 'Foo/Bar.pm', "double colon to slash");
    is(mod2file('Test2::Harness::Util'), 'Test2/Harness/Util.pm', "deep module");
    is(mod2file('Foo'), 'Foo.pm', "single component");
    like(dies { mod2file() }, qr/No module name/, "dies without arg");
};

subtest file2mod => sub {
    is(file2mod('Foo/Bar.pm'), 'Foo::Bar', "slash to double colon");
    is(file2mod('Test2/Harness/Util.pm'), 'Test2::Harness::Util', "deep path");
    is(file2mod('Foo.pm'), 'Foo', "single component");
};

subtest clean_path => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $real = realpath($dir);
    is(clean_path($dir), $real, "resolves real path");
    like(dies { clean_path() }, qr/No path/, "dies without arg");
};

subtest is_same_file => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'test.txt');
    open my $fh, '>', $file or die $!;
    print $fh "x";
    close $fh;

    ok(is_same_file($file, $file), "same path is same file");
    ok(!is_same_file($file, $file . '.other'), "different path is different file");
    ok(!is_same_file(undef, $file), "undef first arg returns false");
    ok(!is_same_file($file, undef), "undef second arg returns false");
};

subtest hash_purge => sub {
    my $h = {a => 1, b => undef, c => {d => 2}, e => {f => undef}};
    my $count = hash_purge($h);
    is($count, 2, "returns count of kept keys");
    ok(!exists $h->{b}, "undef key removed");
    ok(!exists $h->{e}, "empty nested hash removed");
    ok(exists $h->{a}, "defined key kept");
    ok(exists $h->{c}, "non-empty nested hash kept");

    my $empty = {};
    is(hash_purge($empty), 0, "empty hash returns 0");
};

subtest 'read_file and write_file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'test.txt');

    write_file($file, "hello world\n");
    my $content = read_file($file);
    is($content, "hello world\n", "round-trip read/write");

    write_file($file, "line1\n", "line2\n");
    $content = read_file($file);
    is($content, "line1\nline2\n", "write multiple args");

    is(maybe_read_file($file), "line1\nline2\n", "maybe_read_file returns content");
    is(maybe_read_file($file . '.missing'), undef, "maybe_read_file returns undef for missing");
};

subtest write_file_atomic => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'atomic.txt');

    write_file_atomic($file, "atomic content\n");
    is(read_file($file), "atomic content\n", "atomic write works");
    ok(!-e "$file.pend", "no pend file left over");
};

subtest 'lock_file and unlock_file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'lock.txt');

    my $fh = lock_file($file);
    ok($fh, "lock_file returns filehandle");
    ok(unlock_file($fh), "unlock_file succeeds");
};

subtest hub_truth => sub {
    my $f = {hubs => [{id => 1}]};
    is(hub_truth($f), {id => 1}, "returns first hub");

    my $f2 = {trace => {id => 2}};
    is(hub_truth($f2), {id => 2}, "falls back to trace");

    my $f3 = {};
    is(hub_truth($f3), {}, "returns empty hash when nothing");
};

subtest find_in_updir => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $subdir = File::Spec->catdir($dir, 'a', 'b', 'c');
    require File::Path;
    File::Path::make_path($subdir);

    my $file = File::Spec->catfile($dir, 'target.txt');
    open my $fh, '>', $file or die $!;
    close $fh;

    my $orig = Cwd::getcwd();
    chdir($subdir) or die $!;
    my $found = find_in_updir('target.txt');
    chdir($orig) or die $!;

    ok(defined $found, "found file by searching upward");
    like($found, qr/target\.txt$/, "found correct filename");
};

done_testing;
