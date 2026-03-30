use Test2::V0 -target => 'App::Yath::Renderer::QVF';
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

isa_ok($CLASS, ['App::Yath::Renderer::Default'], "inherits from App::Yath::Renderer::Default");
isa_ok($CLASS, ['App::Yath::Renderer'],          "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/init write update_active_disp/);

# --- init(): sets verbose to 100 when original verbose was 0 ---

{
    my $r = make_renderer(verbose => 0);
    is($r->verbose,      100, "init() sets verbose to 100 when unset");
    is($r->real_verbose, 0,   "real_verbose stores original value 0");
}

# --- init(): preserves a non-zero verbose but still captures it in real_verbose ---

{
    my $r = make_renderer(verbose => 2);
    is($r->verbose,      2, "init() keeps explicit verbose value when truthy");
    is($r->real_verbose, 2, "real_verbose stores original verbose 2");
}

# --- job_buffers starts empty ---

{
    my $r = make_renderer();
    my $bufs = $r->job_buffers;
    ok(!defined($bufs) || ref($bufs) eq 'HASH', "job_buffers is undef or hashref");
}

done_testing;
