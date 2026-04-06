use Test2::V0 -target => 'Test2::Harness::Settings';
use File::Temp qw/tempfile/;
use Test2::Harness::Util::JSON qw/encode_json/;

# Verify inheritance from Getopt::Yath::Settings
isa_ok($CLASS, ['Getopt::Yath::Settings'], "Settings inherits from Getopt::Yath::Settings");

# Basic construction
my $one = $CLASS->new();
isa_ok($one, [$CLASS], "Created an instance");

# define_prefix / check_prefix / prefix
ok(!$one->check_prefix('foo'), "foo is not defined");
like(dies { $one->prefix('foo') }, qr/The 'foo' prefix is not defined/, "prefix() croaks on missing");
like(dies { $one->foo }, qr/The 'foo' prefix is not defined/, "AUTOLOAD croaks on missing prefix");

my $pfx = $one->define_prefix('foo');
isa_ok($pfx, ['Test2::Harness::Settings::Prefix'], "define_prefix returns Prefix");
isa_ok($pfx, ['Getopt::Yath::Settings::Group'], "Prefix isa Group");
ok($one->check_prefix('foo'), "foo is now defined");
is($one->prefix('foo'), exact_ref($pfx), "prefix() returns same object");
is($one->foo, exact_ref($pfx), "AUTOLOAD returns same object");

# define_prefix is idempotent
my $pfx2 = $one->define_prefix('foo');
is($pfx2, exact_ref($pfx), "define_prefix returns existing prefix");

# TO_JSON
is($one->TO_JSON, {foo => exact_ref($one->foo)}, "TO_JSON returns hash of prefixes");

# AUTOLOAD error cases
like(dies { $CLASS->bar }, qr/must be called on a blessed instance/, "AUTOLOAD on class");
like(dies { $one->bar(1) }, qr/Too many arguments/, "AUTOLOAD with args");

# build
{
    $INC{'BuildTarget.pm'} = __FILE__;
    package BuildTarget;
    sub new { shift; bless {@_}, 'BuildTarget' };
}

$one->foo->vivify_field('key1');
$one->foo->field('key1', 'val1');
my $built = $one->build('foo', 'BuildTarget', extra => 'e');
isa_ok($built, ['BuildTarget'], "build creates correct class");
is($built->{key1}, 'val1', "build passes prefix data");
is($built->{extra}, 'e', "build passes extra args");

# Construction with hash values (converted to Prefix objects)
my $two = $CLASS->new(
    grp1 => { a => 1, b => 2 },
    grp2 => { c => 3 },
);
isa_ok($two->grp1, ['Test2::Harness::Settings::Prefix'], "Hash values become Prefix");
is($two->grp1->a, 1, "Nested value accessible");
is($two->grp2->c, 3, "Second group accessible");

# Construction with existing Prefix objects
my $prefix_obj = Test2::Harness::Settings::Prefix->new(x => 10);
my $three = $CLASS->new(mygrp => $prefix_obj);
is($three->mygrp, exact_ref($prefix_obj), "Existing Prefix objects preserved");

# Construction rejects non-hash non-Prefix values
like(
    dies { $CLASS->new(bad => []) },
    qr/All prefixes must be defined as hashes/,
    "Rejects arrayref values"
);

like(
    dies { $CLASS->new(bad => bless({}, 'NotAPrefix')) },
    qr/All prefixes must contain instances of Test2::Harness::Settings::Prefix/,
    "Rejects wrong class"
);

# JSON round-trip
my ($fh, $name) = tempfile(UNLINK => 1);
print $fh encode_json($two);
close($fh);

my $four = $CLASS->new($name);
isa_ok($four, [$CLASS], "Deserialized from JSON file");
is($four->grp1->a, 1, "Data survived round-trip");
is($four->grp2->c, 3, "Data survived round-trip (grp2)");

# Group-level compat: group() works as alias
is($one->group('foo'), exact_ref($pfx), "group() works as alias for prefix()");

# group vivify works and returns Prefix
my $viv = $one->group('newgrp', 1);
isa_ok($viv, ['Test2::Harness::Settings::Prefix'], "group(name, vivify) returns Prefix");

# check_group works
ok($one->check_group('foo'), "check_group works for existing");
ok(!$one->check_group('nonexistent'), "check_group returns false for missing");

# maybe works
$one->define_prefix('opts');
$one->opts->vivify_field('verbose');
$one->opts->field('verbose', 1);
is($one->maybe('opts', 'verbose', 0), 1, "maybe returns existing value");
is($one->maybe('opts', 'missing', 42), 42, "maybe returns default for missing option");
is($one->maybe('nope', 'missing', 99), 99, "maybe returns default for missing group");

done_testing;
