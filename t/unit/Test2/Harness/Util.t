use Test2::Bundle::Extended -target => 'Test2::Harness::Util';
#BEGIN { skip_all 'TODO' }

use ok $CLASS => ':ALL';

use File::Temp qw/tempfile tempdir/;

imported_ok qw{
    fqmod
    maybe_open_file
    maybe_read_file
    open_file
    read_file
    write_file
    write_file_atomic

    is_same_file
};

my ($line) = split /\n/, read_file(__FILE__), 2;
like(
    $line,
    q{use Test2::Bundle::Extended -target => 'Test2::Harness::Util';},
    "Read file (only checking first line)"
);

like(
    dies { read_file('/fake/file/that/must/not/exist cause I say so') },
    qr{^\QCould not open file '/fake/file/that/must/not/exist cause I say so' (<)\E},
    "Exception thrown when read_file used on non-existing file"
);

is(
    maybe_read_file(__FILE__),
    read_file(__FILE__),
    "maybe_read_file reads file when it exists"
);

is(
    maybe_read_file('/fake/file/that/must/not/exist cause I say so'),
    undef,
    "maybe_read_file is undef when file does not exist"
);

ok(my $fh = open_file(__FILE__), "opened file");
ok($line = <$fh>, "Can read from file, default mode is 'read'");

if (-e '/dev/null') {
    ok(my $null = open_file('/dev/null', '>'), "opened /dev/null for writing");
    ok((print $null "xxx\n"), "printed to /dev/null");

    is(
        [write_file('/dev/null', "AAA", "BBB")],
        ["AAA", "BBB"],
        "wrote and returned content (/dev/null)"
    );
}

is(
    maybe_open_file('/fake/file/that/must/not/exist cause I say so'),
    undef,
    "maybe_open_file is undef when file does not exist"
);

is(fqmod('Foo::Bar', 'Baz'),       'Foo::Bar::Baz',      "fqmod on postfix");
is(fqmod('Foo::Bar', 'Baz::Bat'),  'Foo::Bar::Baz::Bat', "fqmod on longer postfix");
is(fqmod('Foo::Bar', '+Baz'),      'Baz',                "fqmod on fq");
is(fqmod('Foo::Bar', '+Baz::Bat'), 'Baz::Bat',           "fqmod on longer fq");

my $tmp = tempdir(CLEANUP => 1, TMPDIR => 1);
write_file_atomic(File::Spec->canonpath("$tmp/xxx"), "data");
$fh = open_file(File::Spec->canonpath("$tmp/xxx"), '<');
is(<$fh>, "data", "read data from file");

open($fh, '>', "$tmp/foo");
print $fh "\n";
close($fh);

open($fh, '>', "$tmp/bar");
print $fh "\n";
close($fh);

link("$tmp/foo", "$tmp/foo2") or die "Could not create link: $!";
symlink("$tmp/foo", "$tmp/foo3") or die "Could not create link: $!";

ok(is_same_file("$tmp/foo", "$tmp/foo"), "Matching filenames");
ok(is_same_file("$tmp/foo", "$tmp/foo2"), "hard link");
ok(is_same_file("$tmp/foo", "$tmp/foo3"), "soft link");
ok(!is_same_file("$tmp/foo", "$tmp/bar"), "Different files");

done_testing;
