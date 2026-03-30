use Test2::V0 -target => 'App::Yath::Options::Scheduler';

my $parse = \&App::Yath::Options::Scheduler::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(CLASS()->can('parse_options'), "parse_options() function exists in namespace");
};

subtest "class defaults to Test2::Harness::Scheduler" => sub {
    my $scheduler = $parse->([], no_set_env => 1)->{settings}{scheduler};
    is($scheduler->{class}, 'Test2::Harness::Scheduler', "class defaults to Test2::Harness::Scheduler");
};

subtest "class normalize: fully-qualified with + prefix strips +" => sub {
    my $scheduler = $parse->(['--scheduler', '+Test2::Harness::Scheduler'], no_set_env => 1)->{settings}{scheduler};
    is($scheduler->{class}, 'Test2::Harness::Scheduler', "'+ prefix stripped, fq name kept'");
};

subtest "includes Tests options (tests group)" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    ok(exists $settings->{tests}, "tests group is present (included from Tests)");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->([], no_set_env => 1)->{settings};
    isa_ok($settings->{scheduler}, ['Getopt::Yath::Settings::Group'], "scheduler settings is a Settings::Group");
};

done_testing;
