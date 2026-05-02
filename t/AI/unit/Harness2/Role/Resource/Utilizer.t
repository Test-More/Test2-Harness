use Test2::V0;

use Test2::Harness2::Role::Resource::Utilizer;

# A resource that consumes both Resource and Utilizer. The
# utilize_percent attribute and is_temporarily_unavailable predicate
# are wired through to HashBase slots so the test can drive transitions
# without a real sampler.
{

    package My::Util::Resource;
    use Object::HashBase qw{
        <utilize_percent
        +saturated
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';
    with 'Test2::Harness2::Role::Resource::Utilizer';

    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {ok => 1} }

    sub set_utilize_percent {
        my ($self, $pct) = @_;
        $self->{+UTILIZE_PERCENT} = $self->_validate_utilize_percent($pct);
        return;
    }

    sub is_temporarily_unavailable { $_[0]->{+SATURATED} ? 1 : 0 }

    sub mark_saturated   { $_[0]->{+SATURATED} = 1 }
    sub mark_unsaturated { $_[0]->{+SATURATED} = 0 }
}

# A resource that consumes the role but does not implement the required
# methods. Role::Tiny refuses to compose the role on a class missing
# them; we exercise that directly. (Use a separate package per test so
# Role::Tiny does not cache a successful composition.)
sub _build_unimplemented {
    my $idx = shift;
    my $pkg = "My::BadUtilizer::N$idx";

    eval <<"EOPKG";
package $pkg;
use Object::HashBase;
use Role::Tiny::With;
with 'Test2::Harness2::Role::Resource';
with 'Test2::Harness2::Role::Resource::Utilizer';
sub available { 1 }
sub assign    { 1 }
sub release   { 1 }
sub status    { {} }
1;
EOPKG
    return $@;
}

subtest 'role composes onto a resource and provides required methods' => sub {
    my $r = My::Util::Resource->new;
    ok($r->DOES('Test2::Harness2::Role::Resource'),            'base role applied');
    ok($r->DOES('Test2::Harness2::Role::Resource::Utilizer'),  'utilizer role applied');
    can_ok($r, qw/set_utilize_percent is_temporarily_unavailable utilize_percent/);
};

subtest 'set_utilize_percent stores valid value and rejects invalid' => sub {
    my $r = My::Util::Resource->new;

    $r->set_utilize_percent(50);
    is($r->utilize_percent, 50, 'set 50 stored');

    $r->set_utilize_percent(99.5);
    is($r->utilize_percent, 99.5, 'set 99.5 stored');

    like(
        dies { $r->set_utilize_percent(0) },
        qr/percentage must be > 0 and < 100/,
        'rejects 0',
    );
    like(
        dies { $r->set_utilize_percent(100) },
        qr/percentage must be > 0 and < 100/,
        'rejects 100',
    );
    like(
        dies { $r->set_utilize_percent(-5) },
        qr/requires a numeric percentage/,
        'rejects negative number',
    );
    like(
        dies { $r->set_utilize_percent('abc') },
        qr/requires a numeric percentage/,
        'rejects non-numeric',
    );
    like(
        dies { $r->set_utilize_percent(undef) },
        qr/requires a numeric percentage/,
        'rejects undef',
    );
};

subtest 'is_temporarily_unavailable predicate flips with internal state' => sub {
    my $r = My::Util::Resource->new;
    is($r->is_temporarily_unavailable, 0, 'available by default');

    $r->mark_saturated;
    is($r->is_temporarily_unavailable, 1, 'saturated -> unavailable');

    $r->mark_unsaturated;
    is($r->is_temporarily_unavailable, 0, 'unsaturated -> available again');
};

subtest 'role refuses to compose without required methods' => sub {
    my $err = _build_unimplemented(1);
    like(
        $err,
        qr/Can't apply role .*Test2::Harness2::Role::Resource::Utilizer.* missing.*set_utilize_percent|requires the method.*set_utilize_percent|Can't apply.*missing\b.*set_utilize_percent/i,
        'composition fails when required methods are absent (set_utilize_percent)',
    );
};

subtest 'utilize_percent reads storage slot' => sub {
    # Attribute-only consumer: the role's default utilize_percent
    # accessor falls through to the consumer's HashBase slot.
    my $r = My::Util::Resource->new;
    ok(!defined $r->utilize_percent, 'unset');
    $r->set_utilize_percent(75);
    is($r->utilize_percent, 75, 'reads back after set');
};

done_testing;
