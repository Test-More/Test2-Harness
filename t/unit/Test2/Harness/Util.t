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

subtest sanitize_filename => sub {
    # Normal filename unchanged
    is(sanitize_filename('t/foo/bar.t'), 't/foo/bar.t', "Normal filename unchanged");

    # undef passes through
    is(sanitize_filename(undef), undef, "undef passes through");

    # ANSI CSI sequences stripped (e.g. ESC[0m, ESC[1;31m, ESC[H)
    is(sanitize_filename("t/\e[1mBoo\e[0m.t"), 't/Boo.t', "CSI bold/reset stripped");
    is(sanitize_filename("t/\e[H\e[2J.t"), 't/.t', "CSI cursor home + clear stripped");
    is(sanitize_filename("t/\e[1;31mred\e[0m.t"), 't/red.t', "CSI with params stripped");

    # OSC sequences stripped (ESC ] ... BEL or ESC ] ... ST)
    is(sanitize_filename("t/\e]0;evil title\a.t"), 't/.t', "OSC with BEL stripped");
    is(sanitize_filename("t/\e]0;evil title\e\\.t"), 't/.t', "OSC with ST stripped");

    # Remaining control characters become caret notation
    is(sanitize_filename("t/foo\x01bar.t"), 't/foo^Abar.t', "SOH becomes ^A");
    is(sanitize_filename("t/foo\x7fbar.t"), 't/foo^?bar.t', "DEL becomes ^?");
    is(sanitize_filename("t/foo\tbar.t"), 't/foo^Ibar.t', "Tab becomes ^I");

    # Combined: ANSI stripped first, then control chars escaped
    is(sanitize_filename("t/\e[0J\x01.t"), 't/^A.t', "CSI stripped then ctrl escaped");
};

done_testing;
