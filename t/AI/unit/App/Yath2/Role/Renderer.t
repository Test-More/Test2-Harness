use Test2::V0;

use App::Yath2::Role::Renderer;

# Minimal consumer: only satisfies the required event_in.
package Yath2Test::Renderer::Tiny;
use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';
sub new { bless {seen => []}, shift }
sub seen { $_[0]->{seen} }

sub event_in {
    my ($self, $event) = @_;
    push @{$self->{seen}} => [event_in => $event];
    return;
}

# Full consumer: overrides all four hooks.
package Yath2Test::Renderer::Full;
use Role::Tiny::With;
with 'App::Yath2::Role::Renderer';
sub new { bless {seen => []}, shift }
sub seen { $_[0]->{seen} }

sub start_of_run {
    my $self = shift;
    push @{$self->{seen}} => [start_of_run => {@_}];
    return;
}

sub event_in {
    my ($self, $event) = @_;
    push @{$self->{seen}} => [event_in => $event];
    return;
}

sub end_of_run {
    my $self = shift;
    push @{$self->{seen}} => [end_of_run => {@_}];
    return;
}

sub shutdown {
    my $self = shift;
    push @{$self->{seen}} => ['shutdown'];
    return;
}

# Role compliance check: event_in is required.
package Yath2Test::Renderer::Bad;
sub new { bless {}, shift }

package main;

subtest 'role consumption' => sub {
    ok(
        Role::Tiny::does_role('Yath2Test::Renderer::Tiny', 'App::Yath2::Role::Renderer'),
        'Tiny consumes the renderer role',
    );
    ok(
        Role::Tiny::does_role('Yath2Test::Renderer::Full', 'App::Yath2::Role::Renderer'),
        'Full consumes the renderer role',
    );

    # Enforce required event_in: applying the role to a class that lacks
    # event_in should croak.
    my $ok = eval {
        Role::Tiny->apply_roles_to_package('Yath2Test::Renderer::Bad', 'App::Yath2::Role::Renderer');
        1;
    };
    my $err = $@;
    ok(!$ok, 'role refuses application when event_in is missing');
    like($err, qr/event_in/, 'error names the missing method');
};

subtest 'default hooks are no-ops' => sub {
    my $r = Yath2Test::Renderer::Tiny->new;

    # No start_of_run / end_of_run / shutdown implementations: every
    # one should be dispatchable as a no-op.
    my $ok = eval {
        $r->start_of_run(run_id => 'r-1');
        $r->event_in({event_id => 'e-1', stamp => 0, facet_data => {}});
        $r->end_of_run(run_id => 'r-1', pass_count => 1, fail_count => 0);
        $r->shutdown;
        1;
    };
    ok($ok, 'default hooks run without error');

    # event_in is the only hook Tiny overrides, so only that one should
    # show up in seen().
    is(
        $r->seen,
        [[event_in => {event_id => 'e-1', stamp => 0, facet_data => {}}]],
        'only event_in was dispatched to the consumer',
    );
};

subtest 'full consumer sees every dispatch' => sub {
    my $r = Yath2Test::Renderer::Full->new;

    $r->start_of_run(run_id => 'r-1', mode => 'default');
    $r->event_in({event_id => 'e-1', stamp => 0, facet_data => {}});
    $r->event_in({event_id => 'e-2', stamp => 1, facet_data => {}});
    $r->end_of_run(run_id => 'r-1', pass_count => 2, fail_count => 0);
    $r->shutdown;

    is(
        $r->seen,
        [
            [start_of_run => {run_id => 'r-1',         mode       => 'default'}],
            [event_in     => {event_id => 'e-1',       stamp      => 0, facet_data => {}}],
            [event_in     => {event_id => 'e-2',       stamp      => 1, facet_data => {}}],
            [end_of_run   => {run_id   => 'r-1',       pass_count => 2, fail_count => 0}],
            ['shutdown'],
        ],
        'hooks fire in order with the payloads the layer supplies',
    );
};

done_testing;
