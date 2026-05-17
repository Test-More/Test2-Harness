use strict;
use warnings;

use Test2::V0;

use Scalar::Util qw/isweak/;

use Test2::Harness2::Role::Subsystem;

# Synthetic consumer used throughout the suite. Declares both a harness
# backref slot and an unrelated slot so we can confirm only the harness
# slot is weakened.
package TestConsumer {
    use Object::HashBase qw{ +harness +other };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Subsystem';
}

# Consumer with its own init that should still run alongside the role's
# around hook.
package TestConsumerWithInit {
    use Object::HashBase qw{ +harness +stuff };
    use Role::Tiny::With;
    our @CALLS;
    sub init {
        my $self = shift;
        push @CALLS, 'init';
        $self->{+STUFF} //= 'default';
    }
    with 'Test2::Harness2::Role::Subsystem';
}

# 1. Constructed WITH a harness ref: accessor returns it and the slot
#    is weakened in place.
{
    my $h   = { fake_harness => 1 };
    my $obj = TestConsumer->new(harness => $h, other => 42);

    is($obj->harness, $h, 'harness() returns the passed reference');
    ok(isweak($obj->{harness}), 'harness slot is weakened after init');
    ok(!isweak($obj->{other}),  'unrelated slot is NOT weakened');
}

# 2. Constructed WITHOUT a harness: accessor returns undef and init
#    does not die.
{
    my $obj;
    ok(lives { $obj = TestConsumer->new(other => 7) },
        'construction without a harness does not die')
        or diag $@;
    is($obj->harness, undef, 'harness() returns undef when none passed');
}

# 3. Weaken actually fires: dropping the only strong ref to the harness
#    nukes what the accessor returns.
{
    my $h   = { fake_harness => 1 };
    my $obj = TestConsumer->new(harness => $h);
    is($obj->harness, $h, 'harness present while strong ref is alive');
    undef $h;
    is($obj->harness, undef, 'harness gone after only strong ref drops');
}

# 4. Consumer-supplied init still runs, and the role's hook still weakens
#    the backref after it.
{
    @TestConsumerWithInit::CALLS = ();
    my $h   = { fake_harness => 1 };
    my $obj = TestConsumerWithInit->new(harness => $h);
    is(\@TestConsumerWithInit::CALLS, ['init'], 'consumer init ran');
    is($obj->{stuff}, 'default', 'consumer init defaulted its own slot');
    ok(isweak($obj->{harness}), 'harness slot weakened by role hook');
}

done_testing;
