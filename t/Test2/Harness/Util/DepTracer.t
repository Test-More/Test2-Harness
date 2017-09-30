use Test2::V0 -target => 'Test2::Harness::Util::DepTracer';
# HARNESS-NO-PRELOAD

use ok $CLASS;

my $one = $CLASS->new;
isa_ok($one, [$CLASS], "Made a new instance");
ok(!$one->real_require, "Did not find an existing require hook");

my $two = $CLASS->new;
ref_is($one->my_require, $two->real_require, "Found the existing require hook");

unshift @INC => 't/lib';

require xxx;

is($one->loaded, {}, "Nothing tracked yet");

$one->start;

# use eval so we do not pre-bind the require
eval qq(#line ${ \__LINE__ } "${ \__FILE__ }"\nrequire baz; 1) or die $@;

is($one->loaded, {map {$_ => T} qw/baz.pm foo.pm bar.pm/}, "Loaded 3 modules");

is(
    $one->dep_map, {
        'baz.pm' => [['main', 't/Test2/Harness/Util/DepTracer.t']],
        'foo.pm' => [['baz',  't/lib/baz.pm'], ['bar', 't/lib/bar.pm']],
        'bar.pm' => [['baz',  't/lib/baz.pm']],
    },
    "Built dep-map"
);

$one->stop;

eval "require Data::Dumper; 1" or die $@;

is($one->loaded, {map {$_ => T} qw/baz.pm foo.pm bar.pm/}, "Did not track Data::Dumper");

$one->clear_loaded;
$one->start;

eval "use 5.10.0; 1" or die $@;

is($one->loaded, {}, "Did not track from version import");

done_testing;
