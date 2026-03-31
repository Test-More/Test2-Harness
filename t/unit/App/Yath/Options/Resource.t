use Test2::V0 -target => 'App::Yath::Options::Resource';

my $parse = \&App::Yath::Options::Resource::parse_options;

subtest "module provides options and parse_options" => sub {
    ok(CLASS()->can('options'),       "options() method exists");
    ok(defined &{CLASS() . '::parse_options'}, "parse_options() function is defined");
};

subtest "slots can be set explicitly via -j" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/;

    my $resource = $parse->(['-j', '4'], no_set_env => 1)->{settings}{resource};
    is($resource->{slots},     4, "-j 4 sets slots to 4");
    is($resource->{job_slots}, 4, "job_slots defaults to slots value when not split");
};

subtest "slots:job_slots trigger splits on colon" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/;

    my $resource = $parse->(['-j', '8:2'], no_set_env => 1)->{settings}{resource};
    is($resource->{slots},     8, "-j 8:2 sets slots to 8");
    is($resource->{job_slots}, 2, "-j 8:2 sets job_slots to 2");
};

subtest "slots from env var YATH_JOB_COUNT" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT/;
    local $ENV{YATH_JOB_COUNT} = '6';

    my $resource = $parse->([], no_set_env => 1)->{settings}{resource};
    is($resource->{slots}, 6, "YATH_JOB_COUNT populates slots");
};

subtest "job_slots can be set explicitly" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT T2_HARNESS_JOB_CONCURRENCY/;

    my $resource = $parse->(['-j', '4', '-x', '2'], no_set_env => 1)->{settings}{resource};
    is($resource->{slots},     4, "slots is 4");
    is($resource->{job_slots}, 2, "-x 2 sets job_slots to 2");
};

subtest "post_process ensures slots is at least 1" => sub {
    local %ENV = %ENV;
    delete $ENV{$_} for qw/YATH_JOB_COUNT T2_HARNESS_JOB_COUNT HARNESS_JOB_COUNT T2_HARNESS_JOB_CONCURRENCY/;

    my $resource = $parse->(['-j', '4'], no_set_env => 1)->{settings}{resource};
    ok($resource->{slots} >= 1,     "slots is at least 1 after post_process");
    ok($resource->{job_slots} >= 1, "job_slots is at least 1 after post_process");
};

subtest "classes Map: default contains JobCount resource" => sub {
    my $resource = $parse->([], no_set_env => 1)->{settings}{resource};
    ok(exists $resource->{classes}{'Test2::Harness::Resource::JobCount'},
       "classes defaults to include Test2::Harness::Resource::JobCount");
};

subtest "settings group is correct class" => sub {
    my $settings = $parse->(['-j', '2'], no_set_env => 1)->{settings};
    isa_ok($settings->{resource}, ['Getopt::Yath::Settings::Group'], "resource settings is a Settings::Group");
};

done_testing;
