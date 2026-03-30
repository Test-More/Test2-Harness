use Test2::V0 -target => 'App::Yath::Renderer::Default';
use App::Yath::Theme;

my $settings = bless({}, 'MockSettings');
my $theme    = App::Yath::Theme->new();

sub make_renderer {
    my %extra = @_;
    return $CLASS->new(
        settings => $settings,
        theme    => $theme,
        color    => 0,
        %extra,
    );
}

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/init render_event write finish step/);

# --- Construction ---

ok(my $r = make_renderer(), "can construct with required arguments");

# --- Defaults set by init() ---

ok(defined $r->verbose,       "verbose is set after init");
ok(defined $r->start_time,    "start_time is set after init");

# --- IO handle is initialised ---

ok($r->io, "io handle is set after init");

# --- Composer is initialised ---

isa_ok($r->{composer}, ['App::Yath::Renderer::Default::Composer'],
    "composer is an instance of the Composer class");

# --- color is false when explicitly disabled ---

my $no_color = make_renderer(color => 0);
ok(!$no_color->color, "color is false when color => 0");

# --- weight defaults to 0 (inherited) ---

is($r->weight, 0, "weight() returns 0");

# --- render_event does not die for a minimal event ---

ok(
    lives {
        $r->render_event({
            facet_data => {},
            stamp      => time(),
        });
    },
    "render_event() does not die for a minimal event",
);

done_testing;
