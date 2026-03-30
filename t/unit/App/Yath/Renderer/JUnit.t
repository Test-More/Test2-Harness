use Test2::V0;

# JUnit renderer requires XML::Generator. Skip gracefully if not installed.
eval { require App::Yath::Renderer::JUnit; 1 }
    or skip_all "App::Yath::Renderer::JUnit requires optional dependencies: $@";

our $CLASS = 'App::Yath::Renderer::JUnit';

my $settings = bless({}, 'MockSettings');

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/init render_event finish/);

# --- Construction ---

ok(my $r = $CLASS->new(settings => $settings), "can construct");

# --- init() sets up internal data structures ---

ok($r->{xml},         "init() creates xml generator");
ok($r->{xml_content}, "init() creates xml_content arrayref");
ref_ok($r->{xml_content}, 'ARRAY', "xml_content is an arrayref");
ref_ok($r->{tests},   'HASH',  "init() creates tests hashref");

# --- Default junit_file ---

ok($r->{junit_file}, "init() sets junit_file");

# --- allow_passing_todos respects env var ---

{
    local $ENV{ALLOW_PASSING_TODOS} = '';
    my $r2 = $CLASS->new(settings => $settings);
    ok(!$r2->{allow_passing_todos}, "allow_passing_todos is false when env var not set");
}

{
    local $ENV{ALLOW_PASSING_TODOS} = '1';
    my $r3 = $CLASS->new(settings => $settings);
    ok($r3->{allow_passing_todos}, "allow_passing_todos is true when env var is set");
}

# --- render_event: event without a job_id is silently ignored ---

ok(
    lives {
        $r->render_event({
            facet_data => { harness => {} },
            stamp      => time(),
        });
    },
    "render_event() does not die for event without job_id",
);

done_testing;
