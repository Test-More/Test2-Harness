use Test2::V0 -target => 'Test2::Harness::Settings';
use File::Temp qw/tempfile/;
use Test2::Harness::Util::JSON qw/encode_json/;

my $one = $CLASS->new();
isa_ok($one, [$CLASS], "Created an instance");

ok(!$one->check_prefix('foo'), "foo is not defined");
like(dies { $one->foo }, qr/The 'foo' prefix is not defined/, "Cannot call foo if it is not defined");
like(dies { $one->prefix('foo') }, qr/The 'foo' prefix is not defined/, "Cannot call prefix(foo) if it is not defined");

$one->define_prefix('foo');
isa_ok($one->foo, ['Test2::Harness::Settings::Prefix'], "Defined the prefix");
ok($one->check_prefix('foo'), "foo is now defined");
ok($one->foo, "Can call foo if it is defined");
ok($one->prefix('foo'), "Can call prefix(foo) if it is defined");

is($one->TO_JSON, {foo => exact_ref($one->foo)}, "TO_JSON");

like(dies { $CLASS->foo }, qr/Method foo\(\) must be called on a blessed instance/, "Need a blessed instance");
like(dies { $one->foo(1) }, qr/Too many arguments for foo\(\)/, "No args");

{
    $INC{'XXX.pm'} = __FILE__;
    package XXX;
    sub new { shift; bless {@_}, 'XXX' };
}

$one->foo->vivify_field('xxx');
$one->foo->field(xxx => 'yyy');

my $thing = $one->build('foo', 'XXX', a => 'b');
isa_ok($thing, ['XXX'], "Got a blessed instance of XXX");
is(
    $thing,
    {
        a   => 'b',
        xxx => 'yyy',
    },
    "Instance is composed as expected"
);

my ($fh, $name) = tempfile(UNLINK => 1);
print $fh encode_json($one);
close($fh);

my $two = $CLASS->new($name);
isa_ok($two, [$CLASS], "Correct class");
is($two, $one, "Serialized and deserialized round trip");
ref_is_not($two, $one, "2 different refs");

like(
    dies { $CLASS->new(foo => []) },
    qr/All prefixes must be defined as hashes/,
    "Prefixes must be hashes"
);

like(
    dies { $CLASS->new(foo => bless({}, 'XXX')) },
    qr/All prefixes must contain instances of Test2::Harness::Settings::Prefix/,
    "Blessed Prefixes must be prefixes"
);

done_testing;
