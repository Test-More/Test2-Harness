use Test2::V0 -target => 'App::Yath::Renderer::TAPHarness';

my $settings = bless({}, 'MockSettings');

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/render_event finish/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- render_event is a no-op ---

ok(lives { $r->render_event({}) },    "render_event({}) does not die");
ok(lives { $r->render_event(undef) }, "render_event(undef) does not die");

# --- finish() sets $TAP::Harness::Yath::SUMMARY ---
# We provide a minimal mock auditor whose summary() method returns a sentinel.

{
    package MockAuditor;
    sub new     { bless {}, shift }
    sub summary { 'test-summary-sentinel' }
}

$r->finish(MockAuditor->new());
no strict 'refs';
is(${'TAP::Harness::Yath::SUMMARY'}, 'test-summary-sentinel',
    "finish() stores auditor->summary in \$TAP::Harness::Yath::SUMMARY");

done_testing;
