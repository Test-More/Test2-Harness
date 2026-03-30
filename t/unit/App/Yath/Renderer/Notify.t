use Test2::V0 -target => 'App::Yath::Renderer::Notify';

# Minimal mock settings: provides the notify group with text_module => undef
# so render_event can run its full logic without errors.
{
    package MockNotifyGroup;
    sub new         { bless {}, shift }
    sub text_module { undef }

    package MockNotifySettings;
    sub new    { bless {}, shift }
    sub notify { MockNotifyGroup->new() }
}

my $settings = MockNotifySettings->new();

# Mock event object whose facet_data returns an empty hashref.
{
    package MockNotifyEvent;
    sub new        { bless {}, shift }
    sub facet_data { {} }
}

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/render_event exit_hook/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- render_event does not die for an event with no failures ---

ok(
    lives { $r->render_event(MockNotifyEvent->new()) },
    "render_event() does not die for a no-failure event",
);

# --- Tracking attributes start undef ---

ok(!defined($r->final),        "final attribute starts undef");
ok(!defined($r->tries),        "tries attribute starts undef");
ok(!defined($r->problems),     "problems attribute starts undef");
ok(!defined($r->problem_cids), "problem_cids attribute starts undef");

done_testing;
