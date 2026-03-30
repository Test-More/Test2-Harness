use Test2::V0 -target => 'App::Yath::Renderer::Logger';

# Utility functions in Logger.pm are package subs, not methods.
my $expand           = App::Yath::Renderer::Logger->can('expand');
my $expand_format    = App::Yath::Renderer::Logger->can('expand_log_file_format');
my $normalize        = App::Yath::Renderer::Logger->can('normalize_log_file');

# --- Inheritance ---

isa_ok($CLASS, ['App::Yath::Renderer'], "inherits from App::Yath::Renderer");

# --- Interface ---

can_ok($CLASS, qw/start render_event finish weight/);

# --- weight ---

is(App::Yath::Renderer::Logger->new(settings => bless({}, 'MockSettings'))->weight,
    -100, "weight() is -100");

# --- expand(): letter u returns current USER ---

is($expand->('u', undef), $ENV{USER}, "expand 'u' returns \$ENV{USER}");

# --- expand(): letter p returns PID ---

is($expand->('p', undef), $$, "expand 'p' returns current PID");

# --- expand(): unknown letter is passed through unchanged ---

is($expand->('Z', undef), '%!Z', "expand unknown letter returns literal %!Z");

# --- expand(): letter P returns empty string when no project ---

{
    package MockYath;
    sub new     { bless {}, shift }
    sub project { undef }

    package MockSettingsForP;
    sub new  { bless {}, shift }
    sub yath { MockYath->new() }
    sub maybe { undef }

    package main;
}

my $s_no_project = MockSettingsForP->new();
is($expand->('P', $s_no_project), '', "expand 'P' returns empty string when no project");

# --- expand(): letter P appends ~ when project is set ---

{
    package MockYathWithProject;
    sub new     { bless {}, shift }
    sub project { 'myproject' }

    package MockSettingsWithProject;
    sub new  { bless {}, shift }
    sub yath { MockYathWithProject->new() }
    sub maybe { undef }

    package main;
}

my $s_project = MockSettingsWithProject->new();
is($expand->('P', $s_project), 'myproject~', "expand 'P' returns 'project~'");

# --- normalize_log_file(): no auto_ext leaves filename unchanged (except clean_path) ---

{
    package MockLogging;
    sub new      { bless {}, shift }
    sub auto_ext { 0 }
    sub bzip2    { 0 }
    sub gzip     { 0 }

    package MockSettingsForNorm;
    sub new     { bless {}, shift }
    sub logging { MockLogging->new() }

    package main;
}

my $norm_settings = MockSettingsForNorm->new();
my $result = $normalize->('/tmp/mylog.jsonl', $norm_settings);
like($result, qr{mylog\.jsonl$}, "normalize_log_file preserves .jsonl extension");

# --- normalize_log_file(): auto_ext adds .jsonl if missing ---

{
    package MockLoggingAutoExt;
    sub new      { bless {}, shift }
    sub auto_ext { 1 }
    sub bzip2    { 0 }
    sub gzip     { 0 }

    package MockSettingsAutoExt;
    sub new     { bless {}, shift }
    sub logging { MockLoggingAutoExt->new() }

    package main;
}

my $ae_settings = MockSettingsAutoExt->new();
my $ae_result = $normalize->('/tmp/mylog', $ae_settings);
like($ae_result, qr{mylog\.jsonl$}, "normalize_log_file adds .jsonl when auto_ext is on");

# --- normalize_log_file(): auto_ext + gzip adds .gz suffix ---

{
    package MockLoggingGzip;
    sub new      { bless {}, shift }
    sub auto_ext { 1 }
    sub bzip2    { 0 }
    sub gzip     { 1 }

    package MockSettingsGzip;
    sub new     { bless {}, shift }
    sub logging { MockLoggingGzip->new() }

    package main;
}

my $gz_settings = MockSettingsGzip->new();
my $gz_result = $normalize->('/tmp/mylog', $gz_settings);
like($gz_result, qr{mylog\.jsonl\.gz$}, "normalize_log_file adds .jsonl.gz when auto_ext+gzip");

done_testing;
