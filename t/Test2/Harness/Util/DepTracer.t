use Test2::V0 -target => 'Test2::Harness::Util::DepTracer';
# HARNESS-NO-PRELOAD
# HARNESS-DURATION-SHORT

use ok $CLASS;

unshift @INC => 't/lib';

subtest require_hook => sub {
    my $one = $CLASS->new;
    isa_ok($one, [$CLASS], "Made a new instance");
    ok(!$one->real_require, "Did not find an existing require hook");

    my $two = $CLASS->new;
    ref_is($one->my_require, $two->real_require, "Found the existing require hook");

    require xxx;

    is($one->loaded, {}, "Nothing tracked yet");

    $one->start;

    # use eval so we do not pre-bind the require
    eval qq(#line ${ \__LINE__ } "${ \__FILE__ }"\nrequire baz; 1) or die $@;

    is($one->loaded, {map { $_ => T } qw/baz.pm foo.pm bar.pm/}, "Loaded 3 modules");

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

    is($one->loaded, {map { $_ => T } qw/baz.pm foo.pm bar.pm/}, "Did not track Data::Dumper");

    $one->clear_loaded;
    $one->start;

    eval "use 5.8.9; 1" or die $@;

    is($one->loaded, {}, "Did not track from version import");
};

subtest inc_hook => sub {
    my $one = $CLASS->new;
    isa_ok($one, [$CLASS], "Made a new instance");
    ok($one->real_require, "Did find an existing require hook");

    my $two = $CLASS->new;
    ref_is($one->my_require, $two->real_require, "Found the existing require hook");

    require xxx;

    is($one->loaded, {}, "Nothing tracked yet");

    $one->start;

    # use eval so we do not pre-bind the require
    eval qq(#line ${ \__LINE__ } "${ \__FILE__ }"\nCORE::require('baz_core.pm'); 1) or die $@;

    is($one->loaded, {map { $_ => T } qw/baz_core.pm foo_core.pm bar_core.pm/}, "Loaded 3 modules");

    is(
        $one->dep_map, {
            'baz_core.pm' => [['main', 't/Test2/Harness/Util/DepTracer.t']],
            # The @INC hook is limited, it can catch hidden loads for watching,
            # but it cannot trace deps when a thing is loaded more than once.
            'foo_core.pm' => [['baz_core',  't/lib/baz_core.pm']], #, ['bar', 't/lib/bar_core.pm']],
            'bar_core.pm' => [['baz_core',  't/lib/baz_core.pm']],
        },
        "Built dep-map"
    );

    $one->stop;

    eval "CORE::require('yyy.pm'); 1" or die $@;

    is($one->loaded, {map { $_ => T } qw/baz_core.pm foo_core.pm bar_core.pm/}, "Did not track yyy");

    $one->clear_loaded;
    $one->start;

    eval "use 5.8.9; 1" or die $@;

    is($one->loaded, {}, "Did not track from version import");
};


done_testing;
