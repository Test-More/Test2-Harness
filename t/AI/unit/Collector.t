use Test2::V0;
use v5.38;

use Test2::Harness2::Collector;

# The collector picks its default parser from is_test: a test job parses TAP,
# a non-test job uses the plain IOParser. An explicit parser always wins.

subtest default_parser => sub {
    my $test = Test2::Harness2::Collector->new(
        name    => "collector-test", run_sub  => sub { },
        is_test => 1,                run_uuid => "RUN-1",
    );
    isa_ok(
        $test->parser,
        ['Test2::Harness2::Collector::Parser::TAPParser'],
        "test job defaults to the TAP parser",
    );

    my $non_test = Test2::Harness2::Collector->new(
        name    => "collector-test", run_sub => sub { },
        is_test => 0,
    );
    isa_ok(
        $non_test->parser,
        ['Test2::Harness2::Collector::Parser::IOParser'],
        "non-test job defaults to the IOParser",
    );
    isnt(
        ref($non_test->parser),
        'Test2::Harness2::Collector::Parser::TAPParser',
        "non-test default is not the TAP parser subclass",
    );
};

subtest explicit_parser_wins => sub {
    my $self = Test2::Harness2::Collector->new(
        name    => "collector-test", run_sub  => sub { },
        is_test => 1,                run_uuid => "RUN-1",
        parser  => 'Test2::Harness2::Collector::Parser::IOParser',
    );
    is(
        ref($self->parser),
        'Test2::Harness2::Collector::Parser::IOParser',
        "explicit parser overrides the is_test default",
    );
};

done_testing;
