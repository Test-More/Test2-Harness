use Test2::V0 -target => 'Test2::Tools::HarnessTester';
use Test2::API qw/intercept/;

BEGIN {
    CLASS()->import(qw/summarize_events make_example_dir/);
}

subtest 'summarize_events with passing tests' => sub {
    my $events = intercept {
        ok(1, "pass one");
        ok(1, "pass two");
        done_testing;
    };

    my $summary = summarize_events($events);

    is($summary->{pass},       1, "pass is 1");
    is($summary->{fail},       0, "fail is 0");
    is($summary->{assertions}, 2, "two assertions");
    is($summary->{errors},     0, "no errors");
    is($summary->{failures},   0, "no failures");
    ok(defined $summary->{plan}, "plan is defined");
};

subtest 'summarize_events with failing test' => sub {
    my $events = intercept {
        ok(0, "intentional fail");
        done_testing;
    };

    my $summary = summarize_events($events);

    is($summary->{pass},     0, "pass is 0");
    is($summary->{fail},     1, "fail is 1");
    is($summary->{failures}, 1, "one failure");
};

subtest 'summarize_events returns expected keys' => sub {
    my $events = intercept { done_testing };

    my $summary = summarize_events($events);
    for my $key (qw/pass fail assertions errors failures plan/) {
        ok(exists $summary->{$key}, "summary has key '$key'");
    }
};

subtest 'make_example_dir creates directory with tests' => sub {
    my $dir = make_example_dir();
    ok(-d $dir, "example dir created");
    ok(-d "$dir/t", "t/ subdirectory exists");
};

done_testing;
