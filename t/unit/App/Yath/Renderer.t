use Test2::V0 -target => 'App::Yath::Renderer';

# Minimal subclass used to test the base class contract
package App::Yath::Renderer::TestSub;
use parent 'App::Yath::Renderer';
sub render_event {}

package main;

my $settings = bless({}, 'MockSettings');

# --- Construction ---

like(
    dies { $CLASS->new() },
    qr/'settings' is required/,
    "init() croaks without settings",
);

ok(my $r = $CLASS->new(settings => $settings), "can construct with settings");

# --- Inheritance & interface ---

can_ok($CLASS, qw/
    init render_event
    start step signal finish exit_hook
    weight end_of_events
/);

# --- render_event must be overridden ---

like(
    dies { $r->render_event({}) },
    qr/forgot to override 'render_event\(\)'/,
    "base render_event() croaks — subclass must override",
);

# --- Default weight ---

is($r->weight, 0, "weight() returns 0 by default");

# --- Lifecycle hooks are no-ops ---

ok(lives { $r->start()   }, "start() does not die");
ok(lives { $r->step()    }, "step() does not die");
ok(lives { $r->signal('INT') }, "signal() does not die");
ok(lives { $r->finish()  }, "finish() does not die");
ok(lives { $r->exit_hook() }, "exit_hook() does not die");
ok(lives { $r->end_of_events() }, "end_of_events() does not die");

# --- Subclass satisfies the contract ---

ok(
    my $sub = App::Yath::Renderer::TestSub->new(settings => $settings),
    "subclass with render_event can be constructed",
);
ok(lives { $sub->render_event({}) }, "subclass render_event() does not die");

# --- Attributes are accessible ---

is($r->settings, $settings, "settings attribute is stored");

done_testing;
