use Test2::V0 -target => 'App::Yath::Renderer::Formatter';

# We use a minimal mock formatter so we can instantiate the renderer without a
# real Test2 formatter being present.
{
    package MockFormatter;
    sub new       { bless {}, shift }
    sub write     { }
    sub step      { }
    sub finalize  { }
    sub can {
        my ($self, $meth) = @_;
        return $self->SUPER::can($meth);
    }
}
$INC{'MockFormatter.pm'} = 1;

my $settings = bless({}, 'MockSettings');

sub make_renderer {
    my %extra = @_;
    return $CLASS->new(
        settings  => $settings,
        formatter => 'MockFormatter',
        io        => \*STDOUT,
        io_err    => \*STDERR,
        %extra,
    );
}

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/init render_event step finish formatter/);

# --- Construction ---

ok(my $r = make_renderer(), "can construct with a mock formatter");

# --- formatter attribute is the instantiated formatter object ---

isa_ok($r->formatter, ['MockFormatter'], "formatter attribute holds a MockFormatter instance");

# --- do_step is set based on whether formatter has step() ---

ok($r->do_step, "do_step is true when formatter has step()");

# --- show_job_end defaults to 1 ---

ok($r->show_job_end, "show_job_end defaults to 1");

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

# --- step() delegates to the formatter ---

ok(lives { $r->step() }, "step() does not die");

# --- finish() calls formatter finalize() ---

ok(lives { $r->finish() }, "finish() does not die");

done_testing;
