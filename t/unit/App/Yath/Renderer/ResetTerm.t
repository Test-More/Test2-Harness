use Test2::V0 -target => 'App::Yath::Renderer::ResetTerm';
use Capture::Tiny qw/capture/;

my $settings = bless({}, 'MockSettings');

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/render_event finish weight/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- render_event is a no-op ---

ok(lives { $r->render_event({}) },    "render_event({}) does not die");
ok(lives { $r->render_event(undef) }, "render_event(undef) does not die");

# --- weight ---

is($r->weight, -99999999, "weight() is -99999999");
ok($r->weight < 0, "weight() is negative (runs late)");

# --- finish() is silent when STDOUT is not a TTY ---
# In a test run STDOUT is not a TTY, so no escape sequences are printed.

my ($out) = capture { $r->finish() };
is($out, '', "finish() produces no output when STDOUT is not a TTY");

done_testing;
