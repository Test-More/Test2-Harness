use Test2::V0 -target => 'Test2::Harness::Settings::Prefix';

my $one = $CLASS->new();
isa_ok($one, [$CLASS], "Created an instance");
ref_ok($one, 'REF', "Hash is slightly obscured by an extra deref");

like(
    dies { $one->foo },
    qr/The 'foo' field does not exist/,
    "Must use a valid field"
);

ref_ok($one->vivify_field('foo'), 'SCALAR', "vivify returns a ref");
is($one->foo, undef, "Not set yet");

$one->foo('bar');
is($one->foo, 'bar', "Set value");

if ("$]" >= 5.016) {
    $one->foo = 'baz';
    is($one->foo, 'baz', "Set via lvalue");
}
else {
    $one->field(foo => 'baz');
}

is($one->field('foo'), 'baz', "Got via field");
$one->field('foo', 'xxx');
is($one->field('foo'), 'xxx', "Set via field");

like(
    dies { $one->field('foo', 'bar', 'baz') },
    qr/Too many arguments for field\(\)/,
    "Field only takes 2 args"
);

like(
    dies { $CLASS->foo },
    qr/Method foo\(\) must be called on a blessed instance/,
    "Autload does not work on class"
);

is(
    $one->TO_JSON,
    { foo => 'xxx' },
    "JSON structure"
);

{
    $INC{'TheThing.pm'} = 1;
    package TheThing;
    use Test2::Harness::Util::HashBase qw/foo bar/;
}

my $res = $one->build('TheThing', bar => 'yyy');
isa_ok($res, ['TheThing'], "Created an instance");
is(
    $res,
    {
        foo => 'xxx',
        bar => 'yyy',
    },
    "Created with args"
);

done_testing;
