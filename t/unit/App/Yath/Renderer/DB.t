use Test2::V0;

# App::Yath::Renderer::DB requires several optional modules (Consumer::NonBlock,
# App::Yath::Schema::RunProcessor, etc.).  Skip gracefully when they are absent.
eval { require App::Yath::Renderer::DB; 1 }
    or skip_all "App::Yath::Renderer::DB requires optional dependencies: $@";

our $CLASS = 'App::Yath::Renderer::DB';

my $settings = bless({}, 'MockSettings');

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/init start render_event finish/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- Tracking attributes ---

ok(!defined($r->pid),     "pid starts undef");
ok(!defined($r->writer),  "writer starts undef");
ok(!defined($r->stopped), "stopped starts undef");

# --- render_event is a no-op (data flows to the writer process) ---

ok(lives { $r->render_event({}) }, "render_event() does not die without a writer");

done_testing;
