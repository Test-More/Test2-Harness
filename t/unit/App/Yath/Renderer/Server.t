use Test2::V0;

# App::Yath::Renderer::Server requires Plack and other web-server dependencies.
# Skip gracefully when they are absent.
eval { require App::Yath::Renderer::Server; 1 }
    or skip_all "App::Yath::Renderer::Server requires optional dependencies: $@";

our $CLASS = 'App::Yath::Renderer::Server';

# Server inherits from DB whose init() calls $settings->yath->project.
package MockYath {
    sub new     { bless {project => 'test-project'}, shift }
    sub project { $_[0]->{project} }
}
package MockSettings {
    sub new  { bless {}, shift }
    sub yath { MockYath->new() }
}

my $settings = MockSettings->new();

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer::DB'], "inherits from App::Yath::Renderer::DB");
isa_ok($CLASS, ['App::Yath::Renderer'],     "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/start exit_hook/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- Attributes start undef ---

ok(!defined($r->config), "config attribute starts undef");
ok(!defined($r->server), "server attribute starts undef");

done_testing;
