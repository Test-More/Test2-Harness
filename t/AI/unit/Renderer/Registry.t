use Test2::V0;

use App::Yath2::Renderer::Registry;

# --- resolve_name: built-in short names -----------------------------------

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('terminal');
    is($class,  'App::Yath2::Renderer::Terminal', 'terminal -> Terminal class');
    is($prefix, 'terminal',                        'terminal prefix');
}

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('terminal-auto');
    is($class,  'App::Yath2::Renderer::Terminal', 'terminal-auto -> Terminal class');
    is($prefix, 'terminal',                        'terminal-auto shares the terminal prefix');
}

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('junit');
    is($class,  'App::Yath2::Renderer::JUnit', 'junit -> JUnit class');
    is($prefix, 'junit',                        'junit prefix');
}

# --- resolve_name: +Fully::Qualified --------------------------------------

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('+My::Cool::Renderer');
    is($class,  'My::Cool::Renderer', '+ prefix strips through');
    is($prefix, 'renderer',           'default prefix is lowercased tail');
}

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('+My::Renderer::FooBar');
    is($class,  'My::Renderer::FooBar', 'multi-word tail');
    is($prefix, 'foo-bar',              'CamelCase tail becomes dashed lowercase');
}

# --- resolve_name: dashed fallback ----------------------------------------

{
    my ($class, $prefix) = App::Yath2::Renderer::Registry->resolve_name('some-other-thing');
    is($class,  'App::Yath2::Renderer::SomeOtherThing', 'dashed -> CamelCase under Renderer namespace');
    is($prefix, 'some-other-thing',                      'dashed prefix preserved');
}

# --- resolve_name: missing arg --------------------------------------------

like(
    dies { App::Yath2::Renderer::Registry->resolve_name(undef) },
    qr/name is required/,
    'undef name dies',
);

# --- assert_prefix: ownership rules ---------------------------------------

# Fresh table so other tests do not poison this one.
App::Yath2::Renderer::Registry->_reset_prefix_table;

App::Yath2::Renderer::Registry->assert_prefix('My::A', 'shared');
my $owners = App::Yath2::Renderer::Registry->prefix_owners;
is($owners->{shared}, 'My::A', 'prefix owner recorded');

# Same class re-registering same prefix is fine.
ok(
    lives { App::Yath2::Renderer::Registry->assert_prefix('My::A', 'shared') },
    'same class can re-assert same prefix',
);

# Different class trying to claim the same prefix is fatal at registration.
like(
    dies { App::Yath2::Renderer::Registry->assert_prefix('My::B', 'shared') },
    qr/already owned by 'My::A'.*'My::B'/s,
    'conflicting class cannot claim already-owned prefix',
);

# Distinct prefix is fine.
ok(
    lives { App::Yath2::Renderer::Registry->assert_prefix('My::B', 'other') },
    'other prefix is independently claimable',
);

App::Yath2::Renderer::Registry->_reset_prefix_table;

# --- include_all_renderer_options: prefix ownership at load time ----------

# Load all built-in renderers in one shot. Should not croak; each
# built-in owns a distinct prefix.
require Getopt::Yath::Instance;
my $opts = Getopt::Yath::Instance->new;
ok(
    lives { App::Yath2::Renderer::Registry->include_all_renderer_options($opts) },
    'including all built-in renderers does not raise',
);

my $now = App::Yath2::Renderer::Registry->prefix_owners;
is($now->{terminal}, 'App::Yath2::Renderer::Terminal', 'terminal prefix registered');
is($now->{junit},    'App::Yath2::Renderer::JUnit',    'junit prefix registered');

# Sanity: every renderer option was merged into $opts with its prefix
# applied. We can find at least one --terminal-* and one --junit-* in
# the assembled option-map.
my $map = $opts->option_map;
my %forms;
for my $key (keys %$map) {
    next if $key eq 'custom_match';
    $forms{$key} = 1;
}
ok($forms{'--terminal-verbose'}, '--terminal-verbose registered via include_all_renderer_options');
ok($forms{'--junit-out'},        '--junit-out registered via include_all_renderer_options');

done_testing;
