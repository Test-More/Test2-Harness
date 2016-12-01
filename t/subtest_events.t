use Test2::Bundle::Extended;
use Test2::Harness::Job;
use Test2::Harness::Runner;
use Test2::Harness::Parser;

my @tests = (
    {
        name               => 'T2Harness',
        formatter_env      => 'T2Harness',
        parser_class       => 'EventStream',
        has_encoding_event => 1,
    },
    {
        name          => 'TAP',
        formatter_env => '',
        parser_class  => 'TAP',
    },
);

for my $test (@tests) {
    subtest $test->{name} => sub {
        my @events;

        my $job = Test2::Harness::Job->new(
            id        => 1,
            file      => "t/subtest_events/sample.plx",
            listeners => [sub { shift; push @events => @_ }],
        );

        $job->start(
            runner     => Test2::Harness::Runner->new(),
            start_args => {
                env => {
                    'T2_FORMATTER'       => $test->{formatter_env},
                    'HARNESS_IS_VERBOSE' => 1,
                },
                libs     => ['lib', '.'],
                switches => [],
            },
            parser_class => 'Test2::Harness::Parser',
        );

        $job->step until $job->is_done;

        my @subtests = sort map { $_->subtest_id } grep { $_->subtest_id } @events;

        like(
            \@events,
            array {
                item object {
                    prop 'blessed' => 'Test2::Event::ProcessStart';
                    call 'file'    => 't/subtest_events/sample.plx';
                };
                item object {
                    prop 'blessed'      => 'Test2::Event::ParserSelect';
                    call 'parser_class' => 'Test2::Harness::Parser::' . $test->{parser_class};
                };
                item object {
                    prop 'blessed'    => 'Test2::Event::Note';
                    call 'summary'    => qr/Seeded srand with seed '\d+' from local date\./;
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => FDNE;
                    call 'nested'     => FDNE;
                };
                if ($test->{has_encoding_event}) {
                    item object {
                        prop 'blessed'  => 'Test2::Event::Encoding';
                        call 'encoding' => 'utf8';
                    };
                }

                event Ok => sub {
                    call 'summary'    => 'pass 1';
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => FDNE;
                    call 'nested'     => FDNE;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 2.1';
                    call 'in_subtest' => $subtests[0];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 2.2';
                    call 'in_subtest' => $subtests[0];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 2.3.1';
                    call 'in_subtest' => $subtests[1];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 2.3.2';
                    call 'in_subtest' => $subtests[1];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                };
                event Plan => sub {
                    call 'summary'    => 'Plan is 2 assertions';
                    call 'in_subtest' => $subtests[1];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                    call 'max'        => 2;
                };
                event Subtest => sub {
                    call 'in_subtest' => $subtests[0];
                    call 'subtest_id' => $subtests[1];
                    call 'summary'    => 'foo_buffered_nested';
                    call 'nested'     => 1;
                    call 'subevents'  => array {
                        event Ok => sub {
                            call 'summary'    => 'pass 2.3.1';
                            call 'in_subtest' => $subtests[1];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                        };
                        event Ok => sub {
                            call 'summary'    => 'pass 2.3.2';
                            call 'in_subtest' => $subtests[1];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                        };
                        event Plan => sub {
                            call 'summary'    => 'Plan is 2 assertions';
                            call 'in_subtest' => $subtests[1];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                            call 'max'        => 2;
                        };
                        end;
                    };
                };
                event Plan => sub {
                    call 'summary'    => 'Plan is 3 assertions';
                    call 'in_subtest' => $subtests[0];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                    call 'max'        => 3;
                };
                event Subtest => sub {
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => $subtests[0];
                    call 'summary'    => 'foo_buffered';
                    call 'nested'     => FDNE;
                    call 'subevents'  => array {
                        event Ok => sub {
                            call 'summary'    => 'pass 2.1';
                            call 'in_subtest' => $subtests[0];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                        };
                        event Ok => sub {
                            call 'summary'    => 'pass 2.2';
                            call 'in_subtest' => $subtests[0];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                        };
                        event Subtest => sub {
                            call 'in_subtest' => $subtests[0];
                            call 'subtest_id' => $subtests[1];
                            call 'summary'    => 'foo_buffered_nested';
                            call 'nested'     => 1;
                            call 'subevents'  => array {
                                event Ok => sub {
                                    call 'summary'    => 'pass 2.3.1';
                                    call 'in_subtest' => $subtests[1];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                };
                                event Ok => sub {
                                    call 'summary'    => 'pass 2.3.2';
                                    call 'in_subtest' => $subtests[1];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                };
                                event Plan => sub {
                                    call 'summary'    => 'Plan is 2 assertions';
                                    call 'in_subtest' => $subtests[1];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                    call 'max'        => 2;
                                };
                                end;
                            };
                        };
                        event Plan => sub {
                            call 'summary'    => 'Plan is 3 assertions';
                            call 'in_subtest' => $subtests[0];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                            call 'max'        => 3;
                        };
                    };
                };
                event Note => sub {
                    call 'summary'    => 'Subtest: bar_streamed';
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => FDNE;
                    call 'nested'     => FDNE;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 3.1';
                    call 'in_subtest' => $subtests[2];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 3.2';
                    call 'in_subtest' => $subtests[2];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                };
                event Note => sub {
                    call 'summary'    => 'Subtest: bar_streamed_nested';
                    call 'in_subtest' => $subtests[2];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 3.3.1';
                    call 'in_subtest' => $subtests[3];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                };
                event Ok => sub {
                    call 'summary'    => 'pass 3.3.2';
                    call 'in_subtest' => $subtests[3];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                };
                event Plan => sub {
                    call 'summary'    => 'Plan is 2 assertions';
                    call 'in_subtest' => $subtests[3];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 2;
                    call 'max'        => 2;
                };
                event Subtest => sub {
                    call 'in_subtest' => $subtests[2];
                    call 'subtest_id' => $subtests[3];
                    call 'summary'    => 'Subtest: bar_streamed_nested';
                    call 'nested'     => 1;
                    call 'subevents'  => array {
                        event Ok => sub {
                            call 'summary'    => 'pass 3.3.1';
                            call 'in_subtest' => $subtests[3];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                        };
                        event Ok => sub {
                            call 'summary'    => 'pass 3.3.2';
                            call 'in_subtest' => $subtests[3];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                        };
                        event Plan => sub {
                            call 'summary'    => 'Plan is 2 assertions';
                            call 'in_subtest' => $subtests[3];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 2;
                            call 'max'        => 2;
                        };
                        end;
                    };
                };
                event Plan => sub {
                    call 'summary'    => 'Plan is 3 assertions';
                    call 'in_subtest' => $subtests[2];
                    call 'subtest_id' => FDNE;
                    call 'nested'     => 1;
                    call 'max'        => 3;
                };
                event Subtest => sub {
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => $subtests[2];
                    call 'summary'    => 'Subtest: bar_streamed';
                    call 'nested'     => FDNE;
                    call 'subevents'  => array {
                        event Ok => sub {
                            call 'summary'    => 'pass 3.1';
                            call 'in_subtest' => $subtests[2];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                        };
                        event Ok => sub {
                            call 'summary'    => 'pass 3.2';
                            call 'in_subtest' => $subtests[2];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                        };
                        event Note => sub {
                            call 'summary'    => 'Subtest: bar_streamed_nested';
                            call 'in_subtest' => $subtests[2];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                        };
                        event Subtest => sub {
                            call 'in_subtest' => $subtests[2];
                            call 'subtest_id' => $subtests[3];
                            call 'summary'    => 'Subtest: bar_streamed_nested';
                            call 'subevents'  => array {
                                event Ok => sub {
                                    call 'summary'    => 'pass 3.3.1';
                                    call 'in_subtest' => $subtests[3];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                };
                                event Ok => sub {
                                    call 'summary'    => 'pass 3.3.2';
                                    call 'in_subtest' => $subtests[3];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                };
                                event Plan => sub {
                                    call 'summary'    => 'Plan is 2 assertions';
                                    call 'in_subtest' => $subtests[3];
                                    call 'subtest_id' => FDNE;
                                    call 'nested'     => 2;
                                    call 'max'        => 2;
                                };
                                end;
                            };
                        };
                        event Plan => sub {
                            call 'summary'    => 'Plan is 3 assertions';
                            call 'in_subtest' => $subtests[2];
                            call 'subtest_id' => FDNE;
                            call 'nested'     => 1;
                            call 'max'        => 3;
                        };
                        end;
                    };
                };
                event Plan => sub {
                    call 'summary'    => 'Plan is 3 assertions';
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => FDNE;
                    call 'nested'     => FDNE;
                };
                item object {
                    prop 'blessed'    => 'Test2::Event::ProcessFinish';
                    call 'in_subtest' => FDNE;
                    call 'subtest_id' => FDNE;
                    call 'nested'     => FDNE;
                    call 'result'     => object {
                        call 'total' => 3;
                    };
                };
                end;
            },
            "Got all the events"
        );
    };
}

done_testing;
