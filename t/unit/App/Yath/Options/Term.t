use Test2::V0 -target => 'App::Yath::Options::Term';

my $parse = \&App::Yath::Options::Term::parse_options;

subtest "term_width (width field) can be set via CLI" => sub {
    local %ENV = %ENV;
    delete $ENV{TABLE_TERM_SIZE};

    my $term = $parse->(['--term-size', '120'], no_set_env => 1)->{settings}{term};
    is($term->{width}, 120, "--term-size sets width to 120");
};

subtest "term_width from TABLE_TERM_SIZE env var" => sub {
    local $ENV{TABLE_TERM_SIZE} = '80';
    my $term = $parse->([], no_set_env => 1)->{settings}{term};
    is($term->{width}, '80', "TABLE_TERM_SIZE populates width");
};

subtest "term_width defaults to undef when env var not set" => sub {
    local %ENV = %ENV;
    delete $ENV{TABLE_TERM_SIZE};

    my $term = $parse->([], no_set_env => 1)->{settings}{term};
    is($term->{width}, undef, "width is undef when TABLE_TERM_SIZE not set");
};

subtest "--term-width is an alias for --term-size" => sub {
    local %ENV = %ENV;
    delete $ENV{TABLE_TERM_SIZE};

    my $term = $parse->(['--term-width', '200'], no_set_env => 1)->{settings}{term};
    is($term->{width}, 200, "--term-width alias sets width");
};

subtest "color -c short flag" => sub {
    my $term = $parse->(['-c'], no_set_env => 1)->{settings}{term};
    is($term->{color}, 1, "-c sets color to 1");
};

subtest "color from YATH_COLOR env var" => sub {
    local $ENV{YATH_COLOR} = '1';
    my $term = $parse->([], no_set_env => 1)->{settings}{term};
    is($term->{color}, 1, "YATH_COLOR=1 sets color to 1");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{term}, ['Getopt::Yath::Settings::Group'], "term settings is a Settings::Group");
};

done_testing;
