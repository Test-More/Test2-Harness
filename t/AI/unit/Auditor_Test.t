use v5.38;
use Test2::V0;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor::Test;

# A fake duck-typed try row capturing update() calls.
{
    package Fake::Row;
    use v5.38;
    sub new ($class) { bless { data => {} }, $class }
    sub update ($self, $changes) { %{$self->{data}} = (%{$self->{data}}, %$changes); $self }
    sub field  ($self, $col, @set) { $self->{data}{$col} = $set[0] if @set; $self->{data}{$col} }
}

sub run_events (@facets) {
    my $try = Fake::Row->new;
    my $a = Test2::Harness2::Collector::Auditor::Test->new(try_row => $try);
    $a->startup;
    $a->process_event(Test2::Harness2::Event->new(facet_data => $_)) for @facets;
    $a->shutdown;
    return $try;
}

my $pass = run_events(
    { assert => { pass => 1, details => 'ok 1', number => 1 } },
    { plan   => { count => 1 } },
    { harness_process_exit => { all => 0, sig => 0, err => 0, dmp => 0 } },
);
is($pass->field('passed'), 1, "passing test recorded passed=1");

my $fail = run_events(
    { assert => { pass => 0, details => 'not ok 1', number => 1 } },
    { plan   => { count => 1 } },
    { harness_process_exit => { all => 0, sig => 0, err => 0, dmp => 0 } },
);
is($fail->field('passed'), 0, "failing assertion recorded passed=0");

my $exit = run_events(
    { assert => { pass => 1, details => 'ok 1', number => 1 } },
    { plan   => { count => 1 } },
    { harness_process_exit => { all => 256, sig => 0, err => 1, dmp => 0 } },
);
is($exit->field('passed'), 0, "non-zero exit recorded passed=0");

done_testing;
