use Test2::V0 -target => 'Test2::Harness2::Util';

use ok $CLASS => ':ALL';

use File::Temp qw/tempfile tempdir/;
use File::Spec;

can_ok(
    'main',
    qw{
        maybe_open_file
        maybe_read_file
        open_file
        read_file
        write_file
        write_file_atomic
    }
);

my ($line) = split /\n/, read_file(__FILE__), 2;
like(
    $line,
    q{use Test2::V0 -target => 'Test2::Harness2::Util';},
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

my $tmp = tempdir(CLEANUP => 1, TMPDIR => 1);
write_file_atomic(File::Spec->canonpath("$tmp/xxx"), "data");
$fh = open_file(File::Spec->canonpath("$tmp/xxx"), '<');
is(<$fh>, "data", "read data from file");

done_testing;
