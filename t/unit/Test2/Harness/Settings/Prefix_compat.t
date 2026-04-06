use Test2::V0 -target => 'Test2::Harness::Settings::Prefix';

# Verify inheritance from Getopt::Yath::Settings::Group
isa_ok($CLASS, ['Getopt::Yath::Settings::Group'], "Prefix inherits from Settings::Group");

# Basic construction
my $one = $CLASS->new();
isa_ok($one, [$CLASS], "Created an instance");
ref_ok($one, 'HASH', "Direct hash blessed object (Group-style storage)");

# vivify_field
ref_ok($one->vivify_field('foo'), 'SCALAR', "vivify_field returns a scalar ref");
ok($one->check_field('foo'), "check_field returns true for vivified field");

# The vivified value should be undef until set
is($one->foo, undef, "Vivified field starts as undef");

# Set via scalar ref from vivify_field
my $ref = $one->vivify_field('bar');
$$ref = 'hello';
is($one->bar, 'hello', "Set value via vivify_field scalar ref");

# vivify_field delegates to option_ref
ref_ok($one->option_ref('foo', 1), 'SCALAR', "option_ref works too");

# check_field
ok($one->check_field('foo'), "check_field returns true for existing field");
ok(!$one->check_field('nonexistent'), "check_field returns false for missing field");

# check_field delegates to check_option
ok($one->check_option('foo'), "check_option also works");

# field get/set
$one->field('foo', 'value1');
is($one->field('foo'), 'value1', "field get/set works");

# field as lvalue
if ("$]" >= 5.016) {
    $one->field('foo') = 'lvalue_set';
    is($one->field('foo'), 'lvalue_set', "field works as lvalue");
}

# field croaks on too many args
like(
    dies { $one->field('foo', 'a', 'b') },
    qr/Too many arguments for field\(\)/,
    "field dies on too many args"
);

# field croaks on missing field
like(
    dies { $one->field('nonexistent') },
    qr/The 'nonexistent' field does not exist/,
    "field dies on missing field"
);

# remove_field
$one->vivify_field('to_remove');
$one->field('to_remove', 'gone_soon');
ok($one->check_field('to_remove'), "Field exists before removal");
$one->remove_field('to_remove');
ok(!$one->check_field('to_remove'), "Field removed");

# AUTOLOAD
$one->vivify_field('auto_test');
$one->auto_test('auto_value');
is($one->auto_test, 'auto_value', "AUTOLOAD get/set works");

# AUTOLOAD croaks on missing field (same as Group behavior)
like(
    dies { $one->missing_field_autoload },
    qr/does not exist/,
    "AUTOLOAD croaks on missing field"
);

# AUTOLOAD on class, not instance
like(
    dies { $CLASS->some_method },
    qr/must be called on a blessed instance/,
    "AUTOLOAD needs blessed instance"
);

# TO_JSON
my $json = $one->TO_JSON;
ref_ok($json, 'HASH', "TO_JSON returns hashref");
is($json->{foo}, $one->foo, "TO_JSON has correct data");

# build
{
    $INC{'TestBuildClass.pm'} = __FILE__;
    package TestBuildClass;
    sub new { shift; bless {@_}, 'TestBuildClass' };
}

$one->vivify_field('x');
$one->field('x', 'y');
my $built = $one->build('TestBuildClass', extra => 'arg');
isa_ok($built, ['TestBuildClass'], "build creates correct class");
is($built->{x}, 'y', "build passes prefix data");
is($built->{extra}, 'arg', "build passes extra args");

# Group methods also work
is($one->option('foo'), $one->field('foo'), "option() and field() return same value");
$one->create_option('new_opt', 'new_val');
is($one->option('new_opt'), 'new_val', "create_option works");
$one->delete_option('new_opt');
ok(!$one->check_option('new_opt'), "delete_option works");

# Construction with initial values
my $two = $CLASS->new(a => 1, b => 2);
is($two->a, 1, "Constructed with initial values");
is($two->b, 2, "Constructed with initial values (b)");

done_testing;
