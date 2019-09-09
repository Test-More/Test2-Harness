use Test2::Bundle::Extended -target => 'Test2::Harness::Util';
# HARNESS-DURATION-SHORT

use ok $CLASS => ':ALL';

use File::Temp qw/tempfile tempdir/;

imported_ok qw{
    close_file
    fqmod
    local_env
    maybe_open_file
    maybe_read_file
    open_file
    read_file
    write_file
    write_file_atomic
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

is(fqmod('Foo::Bar', 'Baz'),       'Foo::Bar::Baz',      "fqmod on postfix");
is(fqmod('Foo::Bar', 'Baz::Bat'),  'Foo::Bar::Baz::Bat', "fqmod on longer postfix");
is(fqmod('Foo::Bar', '+Baz'),      'Baz',                "fqmod on fq");
is(fqmod('Foo::Bar', '+Baz::Bat'), 'Baz::Bat',           "fqmod on longer fq");

no warnings 'uninitialized';
local $ENV{FOO} = 'old';
local $ENV{BAZ};
local $ENV{REPLACE_A} = 'old';
local $ENV{REPLACE_B} = undef;
local $ENV{REPLACE_C} = 'old';

local_env {FOO => 'bar', BAZ => 'bat', REPLACE_A => 'xxx', REPLACE_B => 'xxx', REPLACE_C => undef} => sub {
    is($ENV{FOO}, 'bar', "Replaced existing");
    is($ENV{BAZ}, 'bat', "Replaced missing");

    is($ENV{REPLACE_A}, 'xxx', "REPLACE_A was set, but we will change it");
    is($ENV{REPLACE_B}, 'xxx', "REPLACE_B was set, but we will change it");
    is($ENV{REPLACE_C}, undef, "REPLACE_C was set, but we will change it");

    $ENV{REPLACE_A} = undef;
    $ENV{REPLACE_B} = 'new';
    $ENV{REPLACE_C} = 'new'
};

is($ENV{FOO}, 'old', "Restored existing");
is($ENV{BAZ}, undef, "Removed missing");

is($ENV{REPLACE_A}, undef, "REPLACE_A was changed");
is($ENV{REPLACE_B}, 'new', "REPLACE_B was changed");
is($ENV{REPLACE_C}, 'new', "REPLACE_C was changed");

my $tmp = tempdir(CLEANUP => 1, TMPDIR => 1);
write_file_atomic(File::Spec->canonpath("$tmp/xxx"), "data");
$fh = open_file(File::Spec->canonpath("$tmp/xxx"), '<');
is(<$fh>, "data", "read data from file");

done_testing;
