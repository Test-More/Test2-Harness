use Test2::Require::Module 'Test::Harness' => '3.49';
use Test2::V0 -target => 'TAP::Harness::Yath';

subtest 'constructor creates object' => sub {
    my $h = CLASS->new;
    ok($h, "constructed with defaults");
    isa_ok($h, 'TAP::Harness::Yath');
};

subtest 'attribute accessors' => sub {
    my $h = CLASS->new(
        color     => 1,
        jobs      => 4,
        verbosity => 1,
        lib       => ['/foo/lib'],
        switches  => ['-w'],
        timer     => 1,
    );

    is($h->color,     1,          "color");
    is($h->jobs,      4,          "jobs");
    is($h->verbosity, 1,          "verbosity");
    is($h->lib,       ['/foo/lib'], "lib");
    is($h->switches,  ['-w'],      "switches");
    is($h->timer,     1,           "timer");
};

subtest 'runtests method exists' => sub {
    ok(CLASS->can('runtests'), "runtests() method exists");
};

done_testing;
