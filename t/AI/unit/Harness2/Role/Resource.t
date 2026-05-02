use Test2::V0;

use lib 't/lib';
use Test2::Harness2::Test::ResourceService qw//;

# Consumer package defined in-test so we can exercise the role machinery
# independently of any concrete Resource class.
{

    package My::TinyResource;
    use Object::HashBase qw/<available_val +broken +permanent_broken +paused <svc_classes/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { $_[0]->{+AVAILABLE_VAL} // 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
    sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }
    sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }

    sub mark_broken { $_[0]->{+BROKEN} = 1 }

    sub mark_permanent_broken {
        my $self = shift;
        $self->{+PERMANENT_BROKEN} = 1;
        $self->{+BROKEN}           = 1;
    }
    sub mark_paused { $_[0]->{+PAUSED} = 1 }

    sub mark_resumed {
        my $self = shift;
        $self->{+BROKEN} = 0;
        $self->{+PAUSED} = 0;
    }

    sub services {
        my $self    = shift;
        my $classes = $self->{+SVC_CLASSES} // [];
        return map { [$_->[0], name => $_->[1]] } @$classes;
    }
}

{

    package My::LimiterResource;
    use Object::HashBase;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub mark_broken           { }
    sub mark_permanent_broken { }
    sub mark_paused           { }
    sub mark_resumed          { }
}

subtest 'role is applied and provides defaults' => sub {
    my $r = My::TinyResource->new;
    ok($r->DOES('Test2::Harness2::Role::Resource'), 'role composed');
    ok($r->needed,        'default needed=1');
    is($r->resource_name, 'tinyresource', 'default name is lc(last :: part)');
};

subtest 'state transitions' => sub {
    my $r = My::TinyResource->new;
    ok($r->is_usable, 'usable by default');

    $r->mark_broken;
    ok($r->is_broken,  'is_broken');
    ok(!$r->is_usable, 'not usable when broken');

    $r->mark_resumed;
    ok(!$r->is_broken, 'broken cleared');
    ok($r->is_usable,  'usable again');

    $r->mark_paused;
    ok($r->is_paused,  'paused');
    ok(!$r->is_usable, 'not usable when paused');

    $r->mark_resumed;
    ok(!$r->is_paused, 'pause cleared');

    $r->mark_permanent_broken;
    ok($r->is_permanent_broken, 'permanent broken set');
    ok($r->is_broken,           'also marks broken');
    $r->mark_resumed;
    ok(
        $r->is_permanent_broken,
        'permanent brokenness is sticky across mark_resumed'
    );
};

subtest 'services() default is empty list' => sub {
    my $r = My::LimiterResource->new;
    is([$r->services], [], 'no services by default');
};

subtest 'services() returns [class, @params] entries' => sub {
    my $cA = Test2::Harness2::Test::ResourceService::make_service_class(pid => 11);
    my $cB = Test2::Harness2::Test::ResourceService::make_service_class(pid => 12);
    my $r  = My::TinyResource->new(svc_classes => [[$cA, 'alpha'], [$cB, 'beta']]);

    my @s = $r->services;
    is(scalar(@s),       2,                 'two entries');
    is($s[0][0],         $cA,               'first class');
    is([@{$s[0]}[1, 2]], [name => 'alpha'], 'first params include name');
    is($s[1][0],         $cB,               'second class');
    is([@{$s[1]}[1, 2]], [name => 'beta'],  'second params include name');
};

done_testing;
