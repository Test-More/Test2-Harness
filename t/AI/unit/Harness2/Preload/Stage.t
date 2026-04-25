use Test2::V0;

use Test2::Harness2::Preload::Stage;

subtest 'constructor requires a name' => sub {
    my $ok  = eval { Test2::Harness2::Preload::Stage->new; 1 };
    my $err = $@;
    ok(!$ok, 'dies without name');
    like($err, qr/required/, 'error mentions "required"');
};

subtest 'reserved name "base" is rejected' => sub {
    my $ok  = eval { Test2::Harness2::Preload::Stage->new(name => 'base'); 1 };
    my $err = $@;
    ok(!$ok, 'dies on reserved name "base"');
    like($err, qr/reserved/, 'error mentions "reserved"');
};

subtest 'reserved name "NOPRELOAD" is rejected' => sub {
    my $ok  = eval { Test2::Harness2::Preload::Stage->new(name => 'NOPRELOAD'); 1 };
    my $err = $@;
    ok(!$ok, 'dies on reserved name "NOPRELOAD"');
    like($err, qr/reserved/, 'error mentions "reserved"');
};

subtest 'defaults are sensible' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'Foo');
    is($s->name,                 'Foo', 'name set');
    is($s->children,             [],    'children empty');
    is($s->load_sequence,        [],    'load_sequence empty');
    is($s->pre_fork_callbacks,   [],    'pre_fork_callbacks empty');
    is($s->post_fork_callbacks,  [],    'post_fork_callbacks empty');
    is($s->pre_launch_callbacks, [],    'pre_launch_callbacks empty');
    is($s->watches,              {},    'watches empty');
    ok(!$s->eager,               'not eager by default');
};

subtest 'add_child and all_children' => sub {
    my $root  = Test2::Harness2::Preload::Stage->new(name => 'Root');
    my $child = Test2::Harness2::Preload::Stage->new(name => 'Child');
    my $grand = Test2::Harness2::Preload::Stage->new(name => 'Grand');

    $root->add_child($child);
    $child->add_child($grand);

    is(scalar @{$root->children},      1, 'root has one direct child');
    is($root->children->[0]->name, 'Child', 'direct child is Child');

    my $all = $root->all_children;
    is(scalar @$all, 2, 'all_children returns direct + transitive descendants');
    my %names = map { $_->name => 1 } @$all;
    ok($names{Child}, 'Child in all_children');
    ok($names{Grand}, 'Grand in all_children');
};

subtest 'add_to_load_sequence' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'Seq');
    $s->add_to_load_sequence('Scalar::Util', 'List::Util');
    my $cb = sub { 1 };
    $s->add_to_load_sequence($cb);

    is(scalar @{$s->load_sequence}, 3, 'three items in sequence');
    is($s->load_sequence->[0], 'Scalar::Util', 'first item');
    is($s->load_sequence->[1], 'List::Util',   'second item');
    is($s->load_sequence->[2], $cb,            'third is coderef');
};

subtest 'add_to_load_sequence rejects invalid items' => sub {
    my $s  = Test2::Harness2::Preload::Stage->new(name => 'Bad');
    my $ok = eval { $s->add_to_load_sequence({}); 1 };
    ok(!$ok, 'dies on hashref');
    like($@, qr/not a valid preload/, 'error mentions "not a valid preload"');
};

subtest 'do_pre_fork fires callbacks in order' => sub {
    my $s    = Test2::Harness2::Preload::Stage->new(name => 'CBOrder');
    my @log;
    $s->add_pre_fork_callback(sub { push @log => 'a' });
    $s->add_pre_fork_callback(sub { push @log => 'b' });
    $s->do_pre_fork;
    is(\@log, [qw/a b/], 'pre_fork callbacks fired in order');
};

subtest 'do_post_fork fires callbacks in order' => sub {
    my $s   = Test2::Harness2::Preload::Stage->new(name => 'PostFork');
    my @log;
    $s->add_post_fork_callback(sub { push @log => 1 });
    $s->add_post_fork_callback(sub { push @log => 2 });
    $s->do_post_fork;
    is(\@log, [1, 2], 'post_fork callbacks fired in order');
};

subtest 'do_pre_launch fires callbacks in order' => sub {
    my $s   = Test2::Harness2::Preload::Stage->new(name => 'PreLaunch');
    my @log;
    $s->add_pre_launch_callback(sub { push @log => 'x' });
    $s->add_pre_launch_callback(sub { push @log => 'y' });
    $s->do_pre_launch;
    is(\@log, [qw/x y/], 'pre_launch callbacks fired in order');
};

subtest 'add_*_callback rejects non-coderefs' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'NoRef');
    for my $method (qw/add_pre_fork_callback add_post_fork_callback add_pre_launch_callback/) {
        my $ok = eval { $s->$method('not a code'); 1 };
        ok(!$ok, "$method rejects non-coderef");
        like($@, qr/coderef/, 'error mentions "coderef"');
    }
};

subtest 'eager flag' => sub {
    my $s = Test2::Harness2::Preload::Stage->new(name => 'EagerOne');
    ok(!$s->eager, 'not eager initially');
    $s->set_eager(1);
    ok($s->eager, 'eager after set_eager(1)');
};

done_testing;
