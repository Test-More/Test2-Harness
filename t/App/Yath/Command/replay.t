use Test2::V0 -target => 'App::Yath::Command::replay';
# HARNESS-DURATION-SHORT

use ok $CLASS;

subtest simple => sub {
    is($CLASS->group, ' test', "test group");
    ok(!$CLASS->has_runner, "no runner");
    ok(!$CLASS->has_logger, "no logger");
    ok($CLASS->has_display, "has display");
    ok($CLASS->cli_args, "have args");
    ok($CLASS->description, "have a description");
    ok($CLASS->summary, "have a summary");
};

subtest handle_list_args => sub {
    is(
        dies { $CLASS->new(args => {}) },
        "You must specify a log file.\n",
        "Need a log file"
    );

    like(
        dies { $CLASS->new(args => {opts => ['fake.json.bz2']}) },
        qr/Invalid log file/,
        "Need a log valid file"
    );

    my $one = $CLASS->new(args => {opts => ['t/example_log.jsonl.bz2']});
    my $settings = $one->settings;

    is($settings->{log_file}, 't/example_log.jsonl.bz2', "Found log file");
    is($settings->{jobs}, undef, "No jobs");

    $one = $CLASS->new(args => {opts => ['t/example_log.jsonl.bz2', 5, 6]});
    $settings = $one->settings;
    is($settings->{jobs}, {5 => 1, 6 => 1}, "job lookup");
};

subtest feeder => sub {
    my $one = $CLASS->new(args => {opts => ['t/example_log.jsonl.bz2']});
    my $feeder = $one->feeder;
    isa_ok($feeder, ['Test2::Harness::Feeder::JSONL'], "Got a feeder");
    is($feeder->file->name, 't/example_log.jsonl.bz2', "feeder reads from file");
};

subtest run => sub {
    is(
        dies { $CLASS->new },
        "You must specify a log file.\n",
        "Log file is required"
    );

    {
        my $stdout = "";
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die "Could not open fake STDOUT: $!";
        my $one = $CLASS->new(args => {opts => ['t/example_log.jsonl.bz2']});

        is($one->run(), 0, "success");

        like($stdout, qr/ job\s+$_ /, "Saw job $_") for 1 .. 12;
    }

    {
        my $stdout = "";
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die "Could not open fake STDOUT: $!";
        my $one = $CLASS->new(args => {opts => ['t/example_log.jsonl.bz2', 5 ,6]});

        is($one->run(), 0, "success");

        like($stdout, qr/ job\s+$_ /, "Saw job $_") for 5 .. 6;
        unlike($stdout, qr/ job\s+$_ /, "Ignored job $_") for 1 .. 4, 7 .. 12;
    }
};

done_testing;
