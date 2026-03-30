use Test2::V0 -target => 'Test2::Harness::Util::HashBase';

# Declare test classes using HashBase with various attribute specs
{
    package TestHB::Simple;
    use Test2::Harness::Util::HashBase qw/foo bar/;
}

{
    package TestHB::ReadOnly;
    use Test2::Harness::Util::HashBase qw/-ro_attr/;
}

{
    package TestHB::NoSetter;
    use Test2::Harness::Util::HashBase qw/<no_set_attr/;
}

{
    package TestHB::Sub;
    our @ISA = ('TestHB::Simple');
    use Test2::Harness::Util::HashBase qw/baz/;
}

subtest 'new() constructor generated' => sub {
    ok(TestHB::Simple->can('new'), "new() is generated");
    my $obj = TestHB::Simple->new(foo => 1, bar => 2);
    ok($obj, "constructed object");
    isa_ok($obj, 'TestHB::Simple');
};

subtest 'attribute constants generated' => sub {
    is(TestHB::Simple::FOO(), 'foo', "FOO constant");
    is(TestHB::Simple::BAR(), 'bar', "BAR constant");
};

subtest 'accessor methods generated' => sub {
    my $obj = TestHB::Simple->new(foo => 'hello', bar => 'world');
    is($obj->foo, 'hello', "foo getter");
    is($obj->bar, 'world', "bar getter");

    $obj->set_foo('updated');
    is($obj->foo, 'updated', "set_foo setter");
};

subtest 'read-only attribute setter dies' => sub {
    my $obj = TestHB::ReadOnly->new(ro_attr => 'x');
    is($obj->ro_attr, 'x', "read-only getter works");
    # The '-' prefix generates a setter that dies when called
    like(dies { $obj->set_ro_attr('y') }, qr/is read-only/,
        "setter dies for read-only attribute");
};

subtest 'no-setter attribute (<) has getter but no setter' => sub {
    my $obj = TestHB::NoSetter->new(no_set_attr => 'val');
    is($obj->no_set_attr, 'val', "getter works");
    ok(!TestHB::NoSetter->can('set_no_set_attr'), "no setter generated");
};

subtest 'subclass inherits parent attributes' => sub {
    my $obj = TestHB::Sub->new(foo => 1, bar => 2, baz => 3);
    is($obj->foo, 1, "inherited foo");
    is($obj->bar, 2, "inherited bar");
    is($obj->baz, 3, "own baz");
};

subtest 'object is a hash ref' => sub {
    my $obj = TestHB::Simple->new(foo => 'a');
    is(ref($obj), 'TestHB::Simple', "blessed into correct package");
    ok(exists $obj->{foo}, "underlying hash has foo key");
};

done_testing;
