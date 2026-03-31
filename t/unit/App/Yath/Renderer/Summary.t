use Test2::V0;

eval { require App::Yath::Renderer::Summary; 1 }
    or skip_all "App::Yath::Renderer::Summary requires optional dependencies: $@";

eval { require App::Yath::Theme; 1 }
    or skip_all "App::Yath::Theme required: $@";

use Capture::Tiny qw/capture/;

our $CLASS = 'App::Yath::Renderer::Summary';

my $settings = bless({}, 'MockSettings');
my $theme    = App::Yath::Theme->new();

sub make_renderer {
    my %extra = @_;
    return $CLASS->new(
        settings => $settings,
        theme    => $theme,
        quiet    => 0,
        color    => 0,
        %extra,
    );
}

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/render_event exit_hook weight render_summary render_final_data write_summary_file/);

# --- Construction ---

ok(my $r = make_renderer(), "can construct");

# --- render_event is a no-op ---

ok(lives { $r->render_event({}) }, "render_event() does not die");

# --- weight ---

is($r->weight, -99, "weight() is -99");

# --- render_summary: passing run ---

{
    my $renderer = make_renderer();
    my ($out) = capture {
        $renderer->render_summary({
            pass         => 1,
            failures     => 0,
            tests_seen   => 5,
            asserts_seen => 42,
        });
    };

    like($out, qr/PASSED/,            "render_summary shows PASSED for passing run");
    like($out, qr/File Count.*5/,     "render_summary shows file count");
    like($out, qr/Assertion Count.*42/, "render_summary shows assertion count");
}

# --- render_summary: failing run ---

{
    my $renderer = make_renderer();
    my ($out) = capture {
        $renderer->render_summary({
            pass         => 0,
            failures     => 2,
            tests_seen   => 3,
            asserts_seen => 10,
        });
    };

    like($out, qr/FAILED/,         "render_summary shows FAILED for failing run");
    like($out, qr/Fail Count.*2/,  "render_summary shows failure count");
}

# --- render_summary: quiet > 1 suppresses output ---

{
    my $renderer = make_renderer(quiet => 2);
    my ($out) = capture {
        $renderer->render_summary({
            pass         => 1,
            failures     => 0,
            tests_seen   => 1,
            asserts_seen => 1,
        });
    };
    is($out, '', "render_summary produces no output when quiet > 1");
}

# --- render_final_data: failed jobs ---

{
    my $renderer = make_renderer();
    my ($out) = capture {
        $renderer->render_final_data({
            failed => [['job1', 't/foo.t', []]],
        });
    };
    like($out, qr/failed/i, "render_final_data shows failed jobs section");
}

# --- write_summary_file: no file configured means no write ---

{
    my $renderer = make_renderer();
    ok(lives { $renderer->write_summary_file({pass => 1, tests_seen => 1, asserts_seen => 1}, {}) },
        "write_summary_file does not die when no file is configured");
}

done_testing;
