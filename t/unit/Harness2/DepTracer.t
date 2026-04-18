use Test2::V0;
use strict;
use warnings;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::DepTracer;

subtest "start/stop lifecycle" => sub {
    my $dt = Test2::Harness2::DepTracer->new;
    is(Test2::Harness2::DepTracer->ACTIVE, undef, "no active before start");
    $dt->start;
    is(Test2::Harness2::DepTracer->ACTIVE, $dt, "active after start");

    like(
        dies { my $dt2 = Test2::Harness2::DepTracer->new; $dt2->start },
        qr/already an active DepTracer/,
        "double-start refused",
    );

    $dt->stop;
    is(Test2::Harness2::DepTracer->ACTIVE, undef, "cleared on stop");
};

subtest "dep_map captures requires" => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ns  = File::Spec->catdir($tmp, 'DepTracerTest', 'ns');
    make_path($ns);

    for my $mod (qw/A B/) {
        open my $fh, '>', File::Spec->catfile($ns, "$mod.pm") or die $!;
        if ($mod eq 'A') {
            print $fh "package DepTracerTest::ns::A;\nrequire DepTracerTest::ns::B;\n1;\n";
        }
        else {
            print $fh "package DepTracerTest::ns::B;\n1;\n";
        }
        close $fh;
    }

    local @INC = ($tmp, @INC);

    my $dt = Test2::Harness2::DepTracer->new;
    $dt->start;
    require DepTracerTest::ns::A;
    $dt->stop;

    ok($dt->dep_map->{'DepTracerTest/ns/A.pm'}, "A recorded");
    ok($dt->dep_map->{'DepTracerTest/ns/B.pm'}, "B recorded as transitively loaded");

    my $b_loaders = $dt->dep_map->{'DepTracerTest/ns/B.pm'};
    ok((grep { $_->[0] eq 'DepTracerTest::ns::A' } @$b_loaders), "B was loaded by A");
};

subtest "exporter hook records importers" => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $ns  = File::Spec->catdir($tmp, 'DepTracerTest2');
    make_path($ns);

    open my $fh, '>', File::Spec->catfile($ns, "Exp.pm") or die $!;
    print $fh <<'EOPM';
package DepTracerTest2::Exp;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = ('hello');
sub hello { "hi" }
1;
EOPM
    close $fh;

    local @INC = ($tmp, @INC);

    my $dt = Test2::Harness2::DepTracer->new;
    $dt->start;

    eval q{
        package DepTracerTest2::Consumer;
        use DepTracerTest2::Exp 'hello';
        1;
    } or die $@;

    $dt->stop;

    my $importers = $dt->importers_of('DepTracerTest2::Exp');
    is($importers, ['DepTracerTest2::Consumer'], "consumer recorded as importer");

    my $args = $dt->import_args('DepTracerTest2::Exp', 'DepTracerTest2::Consumer');
    is(scalar @$args, 1, "one import call recorded");
    is($args->[0], ['hello'], "import args captured");

    # The exporter hook must be removed after stop.
    is(Test2::Harness2::DepTracer->ACTIVE, undef, "stopped");
};

subtest "record_import (manual)" => sub {
    my $dt = Test2::Harness2::DepTracer->new;
    $dt->record_import('Foo::Bar', 'My::Caller', ['x', 'y']);
    $dt->record_import('Foo::Bar', 'My::Caller', ['z']);
    $dt->record_import('Foo::Bar', 'Another::Caller', []);

    is($dt->importers_of('Foo::Bar'), ['Another::Caller', 'My::Caller'], "sorted importers");

    my $args = $dt->import_args('Foo::Bar', 'My::Caller');
    is($args, [['x', 'y'], ['z']], "both arg sets recorded, deep-copied");
};

subtest "clear_imports" => sub {
    my $dt = Test2::Harness2::DepTracer->new;
    $dt->record_import('A', 'C', []);
    $dt->record_import('B', 'C', []);
    $dt->clear_imports('A');
    is($dt->importers_of('A'), [], "cleared A");
    is($dt->importers_of('B'), ['C'], "B untouched");

    $dt->clear_imports;
    is($dt->importers_of('B'), [], "cleared all");
};

done_testing;
