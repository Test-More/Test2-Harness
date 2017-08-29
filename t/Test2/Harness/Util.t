use Test2::Bundle::Extended -target => 'Test2::Harness::Util';

use ok $CLASS => ':ALL';

use File::Temp qw/tempfile/;

imported_ok qw{
    read_file
    write_file
    write_file_atomic
    open_file
    close_file
    maybe_read_file
    maybe_open_file
    file_stamp
};

like(
    read_file(__FILE__),
    qr/^\Quse Test2::Bundle::Extended -target => 'Test2::Harness::Util';\E$/m,
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
ok(my $line = <$fh>, "Can read from file, default mode is 'read'");
ok(lives { close_file($fh) }, "Closed file");
ok(dies { close_file($fh) }, "already closed");

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

is(
    file_stamp(__FILE__),
    (stat(__FILE__))[9],
    "file_stamp"
);

#TODO: write_file_atomic

done_testing;
