use Test2::V0 -target => 'Test2::Harness::Preload::Stage';

subtest constructor_requires_name => sub {
    like(
        dies { CLASS->new() },
        qr/required/,
        "name is required"
    );
};

subtest reserved_names => sub {
    like(
        dies { CLASS->new(name => 'base') },
        qr/reserved/,
        "'base' is a reserved name"
    );

    like(
        dies { CLASS->new(name => 'NOPRELOAD') },
        qr/reserved/,
        "'NOPRELOAD' is a reserved name"
    );
};

subtest construction => sub {
    my $s = CLASS->new(name => 'mystage');
    ok($s, "stage created");
    is($s->name, 'mystage', "name accessor");
    is(ref($s->children), 'ARRAY', "children is arrayref");
    is(ref($s->pre_fork_callbacks), 'ARRAY', "pre_fork_callbacks is arrayref");
    is(ref($s->post_fork_callbacks), 'ARRAY', "post_fork_callbacks is arrayref");
    is(ref($s->pre_launch_callbacks), 'ARRAY', "pre_launch_callbacks is arrayref");
    is(ref($s->load_sequence), 'ARRAY', "load_sequence is arrayref");
    is(ref($s->watches), 'HASH', "watches is hashref");
};

subtest add_pre_fork_callback => sub {
    my $s = CLASS->new(name => 'stage1');

    like(
        dies { $s->add_pre_fork_callback("not a code") },
        qr/coderef/i,
        "requires coderef"
    );

    my $called = 0;
    $s->add_pre_fork_callback(sub { $called++ });
    is(scalar @{$s->pre_fork_callbacks}, 1, "callback added");

    $s->do_pre_fork();
    is($called, 1, "pre_fork callback was called");
};

subtest add_post_fork_callback => sub {
    my $s = CLASS->new(name => 'stage2');

    like(
        dies { $s->add_post_fork_callback("not a code") },
        qr/coderef/i,
        "requires coderef"
    );

    my $called = 0;
    $s->add_post_fork_callback(sub { $called++ });
    $s->do_post_fork();
    is($called, 1, "post_fork callback was called");
};

subtest add_pre_launch_callback => sub {
    my $s = CLASS->new(name => 'stage3');

    like(
        dies { $s->add_pre_launch_callback("not a code") },
        qr/coderef/i,
        "requires coderef"
    );

    my $called = 0;
    $s->add_pre_launch_callback(sub { $called++ });
    $s->do_pre_launch();
    is($called, 1, "pre_launch callback was called");
};

subtest add_child_and_all_children => sub {
    my $parent = CLASS->new(name => 'parent');
    my $child1 = CLASS->new(name => 'child1');
    my $child2 = CLASS->new(name => 'child2');
    my $grandchild = CLASS->new(name => 'grandchild');

    $parent->add_child($child1);
    $parent->add_child($child2);
    $child1->add_child($grandchild);

    is(scalar @{$parent->children}, 2, "parent has 2 direct children");

    my $all = $parent->all_children;
    is(ref($all), 'ARRAY', "all_children returns arrayref");
    is(scalar @$all, 3, "all_children returns all 3 descendants");
};

subtest add_to_load_sequence => sub {
    my $s = CLASS->new(name => 'loader');

    $s->add_to_load_sequence('Some::Module');
    $s->add_to_load_sequence(sub { });

    is(scalar @{$s->load_sequence}, 2, "two items added to load sequence");

    like(
        dies { $s->add_to_load_sequence([]) },
        qr/valid preload/i,
        "rejects invalid item types"
    );
};

done_testing;
