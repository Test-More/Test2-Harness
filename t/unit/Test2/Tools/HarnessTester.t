use Test2::V0 -target => 'Test2::Tools::HarnessTester';
use Test2::Tools::HarnessTester qw/summarize_events/;

imported_ok qw/summarize_events/;

my $events = intercept {
    ok(1, "Pass") for 1 .. 4;
    ok(0, "Fail");
    ok(1, "Pass");

    done_testing;
};

is(
    summarize_events($events),
    {
        assertions => 6,
        errors     => 0,
        fail       => 1,
        failures   => 1,
        pass       => 0,
        plan       => {count => 6},
    },
    "Failure, assertion count, plan",
);

$events = intercept {
    ok(1, "Pass") for 1 .. 4;

    done_testing;
};

is(
    summarize_events($events),
    {
        assertions => 4,
        errors     => 0,
        fail       => 0,
        failures   => 0,
        pass       => 1,
        plan       => {count => 4},
    },
    "pass, assertion count, plan",
);

done_testing;
