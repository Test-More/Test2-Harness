use Test2::V0 -target => 'App::Yath::Options::Renderer';

my $parse = \&App::Yath::Options::Renderer::parse_options;

subtest "default values" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_COLOR CLICOLOR_FORCE T2_HARNESS_IS_VERBOSE HARNESS_IS_VERBOSE TABLE_TERM_SIZE/;

    my $r = $parse->([], no_set_env => 1)->{settings}{renderer};

    is($r->{quiet},    0, "quiet defaults to 0");
    is($r->{verbose},  0, "verbose defaults to 0 (Count type initialized to 0)");
    is($r->{qvf},      0, "qvf defaults to 0");
    is($r->{wrap},     1, "wrap defaults to 1");
    is($r->{theme},    'App::Yath::Theme::Default', "theme defaults to App::Yath::Theme::Default");
};

subtest "default classes include Default and Summary renderers" => sub {
    my $r = $parse->([], no_set_env => 1)->{settings}{renderer};
    ok(exists $r->{classes}{'App::Yath::Renderer::Default'},  "Default renderer in classes");
    ok(exists $r->{classes}{'App::Yath::Renderer::Summary'},  "Summary renderer in classes");
};

subtest "quiet Bool flag" => sub {
    my $r = $parse->(['-q'], no_set_env => 1)->{settings}{renderer};
    is($r->{quiet}, 1, "-q sets quiet to 1");
};

subtest "verbose Count type increments" => sub {
    my $r1 = $parse->(['-v'], no_set_env => 1)->{settings}{renderer};
    my $r2 = $parse->(['-v', '-v'], no_set_env => 1)->{settings}{renderer};
    ok($r1->{verbose} > 0, "-v increments verbose");
    ok($r2->{verbose} > $r1->{verbose}, "-v -v increments verbose higher");
};

subtest "verbose Count: explicit value" => sub {
    my $r = $parse->(['--verbose=3'], no_set_env => 1)->{settings}{renderer};
    is($r->{verbose}, 3, "--verbose=3 sets count to 3");
};

subtest "qvf Bool flag" => sub {
    my $r = $parse->(['--qvf'], no_set_env => 1)->{settings}{renderer};
    is($r->{qvf}, 1, "--qvf sets qvf to 1");
};

subtest "wrap Bool flag" => sub {
    my $r = $parse->(['--no-wrap'], no_set_env => 1)->{settings}{renderer};
    is($r->{wrap}, 0, "--no-wrap disables wrap");
};

subtest "theme normalize: short name gets namespace prepended" => sub {
    my $r = $parse->(['--theme', 'Default'], no_set_env => 1)->{settings}{renderer};
    is($r->{theme}, 'App::Yath::Theme::Default', "short theme name expands to full namespace");
};

subtest "theme normalize: fully-qualified name with + prefix" => sub {
    my $r = $parse->(['--theme', '+App::Yath::Theme::Default'], no_set_env => 1)->{settings}{renderer};
    is($r->{theme}, 'App::Yath::Theme::Default', "'+' prefix stripped from theme");
};

subtest "includes Term options (term group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{term}, "term group is present (included from Term)");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{renderer}, ['Getopt::Yath::Settings::Group'], "renderer settings is a Settings::Group");
};

done_testing;
