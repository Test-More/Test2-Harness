use Test2::V0;

use Test2::Harness2::Role::Plugin;

# Stubby consumer -- takes the role but overrides nothing. Used to
# verify every declared hook has a working default and returns the
# documented "no answer" shape.
package HarnessBare;
use Role::Tiny::With;
with 'Test2::Harness2::Role::Plugin';
sub new { bless {}, shift }

# Consumer that overrides a handful of hooks so we can verify
# dispatch on a real consumer still hits overridden methods.
package HarnessOver;
use Role::Tiny::With;
with 'Test2::Harness2::Role::Plugin';
sub new { bless { seen => [] }, shift }
sub seen { $_[0]->{seen} }
sub tick {
    my $self = shift;
    push @{ $self->{seen} } => [tick => [@_]];
    return;
}
sub run_queued {
    my $self = shift;
    push @{ $self->{seen} } => [run_queued => [@_]];
    return;
}
sub duration_data    { return { 't/foo.t' => 'short' } }
sub coverage_data    { return { 'lib/X.pm' => ['t/a.t'] } }
sub changed_files    { return ('a.pm', 'b.pm') }
sub changed_diff     { return (diff => 'D1') }
sub claim_file       { return 'claimed' }
sub munge_files      { push @{$_[0]->{seen}} => ['munge_files', [@_[1..$#_]]]; return; }
sub instance_setup   { push @{$_[0]->{seen}} => ['instance_setup', [@_[1..$#_]]]; return; }

package main;

subtest 'role consumption' => sub {
    ok(Role::Tiny::does_role('HarnessBare', 'Test2::Harness2::Role::Plugin'),
        'HarnessBare consumes the harness plugin role');
    ok(Role::Tiny::does_role('HarnessOver', 'Test2::Harness2::Role::Plugin'),
        'HarnessOver also consumes the role');
};

subtest 'default no-answer values' => sub {
    my $p = HarnessBare->new;

    # Callback-style hooks: no-op default; return value irrelevant but
    # should not die or warn.
    ok(lives { $p->tick(type => 'run') },          'tick ok');
    ok(lives { $p->run_queued({}) },               'run_queued ok');
    ok(lives { $p->run_complete({}) },             'run_complete ok');
    ok(lives { $p->run_halted({}, 'reason') },     'run_halted ok');
    ok(lives { $p->instance_setup(x => 1) },       'instance_setup ok');
    ok(lives { $p->instance_teardown },            'instance_teardown ok');
    ok(lives { $p->instance_finalize },            'instance_finalize ok');
    ok(lives { $p->setup },                        'setup ok');
    ok(lives { $p->teardown },                     'teardown ok');
    ok(lives { $p->munge_search([], [], {}) },     'munge_search ok');
    ok(lives { $p->munge_files([], {}) },          'munge_files ok');
    ok(lives { $p->post_process_coverage_tests({}, []) }, 'post_process ok');

    # Data hooks: undef or empty list.
    is($p->claim_file('t/x.t', {}), undef, 'claim_file default undef');
    is($p->duration_data({}, []),   undef, 'duration_data default undef');
    is($p->coverage_data([]),        undef, 'coverage_data default undef');
    is([$p->changed_files({})],      [],    'changed_files default empty');
    is([$p->changed_diff({})],       [],    'changed_diff default empty');
};

subtest 'overridden hooks dispatch to consumer impls' => sub {
    my $p = HarnessOver->new;

    $p->tick(type => 'run');
    $p->run_queued({ id => 42 });
    $p->instance_setup(run => 'R', job => 'J');
    $p->munge_files([ 't/a.t' ], { key => 'v' });

    my @names = map { $_->[0] } @{ $p->seen };
    is(\@names,
        ['tick', 'run_queued', 'instance_setup', 'munge_files'],
        'hook methods called in order on the overriding consumer',
    );

    is($p->duration_data({}, []), { 't/foo.t' => 'short' }, 'duration_data overridden');
    is($p->coverage_data([]),     { 'lib/X.pm' => ['t/a.t'] }, 'coverage_data overridden');
    is([$p->changed_files({})], ['a.pm', 'b.pm'], 'changed_files list override');
    is([$p->changed_diff({})],  ['diff', 'D1'],   'changed_diff list override');
    is($p->claim_file('t/x.t', {}), 'claimed', 'claim_file overridden');
};

subtest 'TO_JSON serialization' => sub {
    # Default TO_JSON is: ref($_[0]) || "$_[0]"
    # Class invocation -> $_[0] is the class string, ref() is empty, falls
    # through to "$_[0]" (the class name). Instance invocation -> ref()
    # returns the blessed class, which is truthy, so we still get the
    # class name back. Either way: the class name.
    is(HarnessBare->TO_JSON, 'HarnessBare', 'class-level stringifies to class name');
    my $inst = HarnessBare->new;
    is($inst->TO_JSON, 'HarnessBare', 'instance stringifies to its class name');
};

done_testing;
