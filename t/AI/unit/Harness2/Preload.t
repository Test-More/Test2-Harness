use Test2::V0;

use File::Temp qw/tempfile/;

use Test2::Harness2::Preload;
use Test2::Harness2::Preload::Stage;

subtest 'Stage basics' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'foo');

    is($s->name,                 'foo', 'name recorded');
    is($s->children,             [],    'children default empty');
    is($s->load_sequence,        [],    'load_sequence default empty');
    is($s->pre_fork_callbacks,   [],    'pre_fork_callbacks empty');
    is($s->post_fork_callbacks,  [],    'post_fork_callbacks empty');
    is($s->pre_launch_callbacks, [],    'pre_launch_callbacks empty');
    is($s->watches,              {},    'watches default empty');
    ok(!$s->eager, 'not eager by default');

    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'base') },
        qr/'base' is reserved/,
        "'base' is reserved",
    );

    like(
        dies { Test2::Harness2::Preload::Stage->new(name => 'NOPRELOAD') },
        qr/'NOPRELOAD' is reserved/,
        "'NOPRELOAD' is reserved",
    );

    like(
        dies { Test2::Harness2::Preload::Stage->new() },
        qr/'name' is a required attribute/,
        'name is required',
    );
};

subtest 'Stage add_to_load_sequence' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'foo');

    $s->add_to_load_sequence('Foo::Bar', 'Baz', sub { 1 });
    is(scalar @{$s->load_sequence}, 3,          'three items added');
    is($s->load_sequence->[0],      'Foo::Bar', 'first is module name');
    is($s->load_sequence->[1],      'Baz',      'second is module name');
    is(ref($s->load_sequence->[2]), 'CODE',     'third is coderef');

    like(
        dies { $s->add_to_load_sequence(\'bogus') },
        qr/not a valid preload/,
        'refs other than CODE are rejected',
    );
};

subtest 'Stage callbacks' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'foo');

    my @log;
    $s->add_pre_fork_callback(sub { push @log => [pre_fork => @_] });
    $s->add_post_fork_callback(sub { push @log => [post_fork => @_] });
    $s->add_pre_launch_callback(sub { push @log => [pre_launch => @_] });

    $s->do_pre_fork('a');
    $s->do_post_fork('b');
    $s->do_pre_launch('c');

    is(
        \@log,
        [
            [pre_fork   => 'a'],
            [post_fork  => 'b'],
            [pre_launch => 'c'],
        ],
        'callbacks fire in registration order',
    );

    like(
        dies { $s->add_pre_fork_callback('not a coderef') },
        qr/Callback must be a coderef/,
        'scalar rejected',
    );
};

subtest 'Stage watch' => sub {
    my ($fh, $file) = tempfile(UNLINK => 1);
    close $fh;

    my $s = Test2::Harness2::Preload::Stage->new(name => 'w');

    my $cb = sub { 1 };
    $s->watch($file, $cb);
    ok(exists $s->watches->{$file}, 'watch recorded by abs path');

    like(
        dies { $s->watch($file, $cb) },
        qr/already a watch/,
        'second watch on the same file dies',
    );

    like(
        dies { $s->watch($file, 'not a coderef') },
        qr/callback argument is required/,
        'rejects non-coderef callback',
    );

    like(
        dies { $s->watch('/no/such/path/exists/' . $$, $cb) },
        qr/first argument must be a file/,
        'rejects missing file',
    );
};

subtest 'DSL build_stage' => sub {
    my $meta = Test2::Harness2::Preload->new;

    $meta->build_stage(
        name => 'outer',
        code => sub {
            my $stage = shift;
            $stage->add_to_load_sequence('X');
        },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    is(scalar @{$meta->stage_list},                 1,       'one top-level stage added');
    is($meta->stage_list->[0]->name,                'outer', 'outer registered');
    is($meta->stage_lookup->{outer}->load_sequence, ['X'],   'load_sequence captured');
};

subtest 'DSL nested stages' => sub {
    my $meta = Test2::Harness2::Preload->new;

    $meta->build_stage(
        name => 'parent',
        code => sub {
            my $parent = shift;
            $parent->add_to_load_sequence('P');

            # Inside the build, nested stages are created via the
            # outer meta's build_stage too -- the DSL's `stage` export
            # wires this exact shape.
            $meta->build_stage(
                name => 'child',
                code => sub {
                    my $child = shift;
                    $child->add_to_load_sequence('C');
                },
                caller => [__PACKAGE__, __FILE__, __LINE__],
            );
        },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    is(scalar @{$meta->stage_list}, 1, 'one top-level stage');

    my $parent = $meta->stage_list->[0];
    is($parent->name, 'parent', 'parent registered');

    is(scalar @{$parent->children},  1,       'parent has one child');
    is($parent->children->[0]->name, 'child', 'child nested under parent');

    # Both parent and child are resolvable via the stage_lookup.
    ok(exists $meta->stage_lookup->{parent}, 'parent lookup');
    ok(exists $meta->stage_lookup->{child},  'child lookup');
};

subtest 'DSL duplicate stage dies' => sub {
    my $meta = Test2::Harness2::Preload->new;

    $meta->build_stage(
        name   => 'dup',
        code   => sub { shift->add_to_load_sequence('A') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    like(
        dies {
            $meta->build_stage(
                name   => 'dup',
                code   => sub { shift->add_to_load_sequence('B') },
                caller => [__PACKAGE__, __FILE__, __LINE__],
            );
        },
        qr/A stage named 'dup' was already defined/,
        'duplicate stage name is rejected',
    );
};

subtest 'default_stage fallback' => sub {
    my $meta = Test2::Harness2::Preload->new;
    is($meta->default_stage, undef, 'no stages => undef default');

    $meta->build_stage(
        name   => 'first',
        code   => sub { shift->add_to_load_sequence('A') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    is($meta->default_stage, 'first', 'first stage is the implicit default');

    $meta->build_stage(
        name   => 'second',
        code   => sub { shift->add_to_load_sequence('B') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    is($meta->default_stage, 'first', 'second stage does not displace the implicit default');

    $meta->set_default_stage('second');
    is($meta->default_stage, 'second', 'explicit set wins');

    like(
        dies { $meta->set_default_stage('first') },
        qr/Default stage already set/,
        'second set_default_stage dies',
    );
};

subtest 'eager_stages' => sub {
    my $meta = Test2::Harness2::Preload->new;

    $meta->build_stage(
        name => 'p',
        code => sub {
            my $parent = shift;
            $parent->set_eager(1);

            $meta->build_stage(
                name   => 'c1',
                code   => sub { 1 },
                caller => [__PACKAGE__, __FILE__, __LINE__],
            );

            $meta->build_stage(
                name   => 'c2',
                code   => sub { 1 },
                caller => [__PACKAGE__, __FILE__, __LINE__],
            );
        },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    is(
        $meta->eager_stages,
        {p => ['c1', 'c2']},
        'eager parent lists its children by name',
    );
};

subtest 'DSL import installs exports' => sub {

    package My::Preload::Lib;
    use Test2::Harness2::Preload;

    stage outer => sub {
        preload 'Scalar::Util';
        preload sub { 1 };

        stage inner => sub {
            preload 'List::Util';
            eager();
        };

        default();
    };

    package main;

    ok(
        My::Preload::Lib->can('TEST2_HARNESS_PRELOAD'),
        'marker sub installed on caller'
    );

    my $meta = My::Preload::Lib::TEST2_HARNESS_PRELOAD();
    isa_ok($meta, 'Test2::Harness2::Preload');

    is(scalar @{$meta->stage_list}, 1, 'one top-level stage');

    my $outer = $meta->stage_list->[0];
    is($outer->name,                    'outer',        'outer stage registered');
    is(scalar @{$outer->load_sequence}, 2,              'outer has two load items');
    is($outer->load_sequence->[0],      'Scalar::Util', 'module name first');
    is(ref($outer->load_sequence->[1]), 'CODE',         'coderef second');

    my $inner = $outer->children->[0];
    is($inner->name,          'inner',        'inner stage nested');
    is($inner->load_sequence, ['List::Util'], 'inner has one load item');
    ok($inner->eager, 'inner stage is eager');

    is($meta->default_stage, 'outer', 'default() fired on outer');
};

subtest 'DSL merge' => sub {
    my $a = Test2::Harness2::Preload->new;
    $a->build_stage(
        name   => 'alpha',
        code   => sub { shift->add_to_load_sequence('A') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    my $b = Test2::Harness2::Preload->new;
    $b->build_stage(
        name   => 'beta',
        code   => sub { shift->add_to_load_sequence('B') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    $a->merge($b);

    is(scalar @{$a->stage_list}, 2, 'merge appended the other meta');
    ok(exists $a->stage_lookup->{alpha}, 'alpha still resolvable');
    ok(exists $a->stage_lookup->{beta},  'beta now resolvable');

    # Duplicate merge fails via the lookup collision path.
    my $c = Test2::Harness2::Preload->new;
    $c->build_stage(
        name   => 'alpha',
        code   => sub { shift->add_to_load_sequence('X') },
        caller => [__PACKAGE__, __FILE__, __LINE__],
    );

    like(
        dies { $a->merge($c) },
        qr/A stage named 'alpha' was already defined/,
        'merge rejects colliding stage name',
    );
};

done_testing;
