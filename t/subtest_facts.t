use Test2::Bundle::Extended;
use Test2::Harness::Job;
use Test2::Harness::Runner;
use Test2::Harness::Parser;

subtest T2Harness => sub {
    my @facts;

    my $job = Test2::Harness::Job->new(
        id        => 1,
        file      => "t/subtest_facts/sample.plx",
        listeners => [sub { shift; push @facts => @_ }],
    );

    $job->start(
        runner     => Test2::Harness::Runner->new(),
        start_args => {
            env => {
                'T2_FORMATTER'       => 'T2Harness',
                'HARNESS_IS_VERBOSE' => 1,
            },
            libs     => ['lib', '.'],
            switches => [],
        },
        parser_class => 'Test2::Harness::Parser',
    );

    $job->step until $job->is_done;

    my @subtests = sort map { $_->is_subtest } grep { $_->is_subtest } @facts;

    like(
        \@facts,
        array {
            item object {call 'start'         => 't/subtest_facts/sample.plx'};
            item object {call 'parser_select' => 'Test2::Harness::Parser::EventStream'};
            item object {
                call 'summary'    => qr/Seeded srand with seed '\d+' from local date\./;
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
            };
            item object {call 'encoding' => 'utf8'};
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Plan is 2 assertions';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
            };
            item object {
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => $subtests[1];
                call 'summary'    => 'foo_nested';
                call 'nested'     => 1;
                call 'number'     => 3;
                call 'result'     => {
                    'name'   => 'foo_nested',
                    'nested' => 2,
                    'total'  => 2,
                    'facts'  => [
                        {
                            '_summary'   => 'pass',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                            'number'     => 1,
                        },
                        {
                            '_summary'   => 'pass',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                            'number'     => 2,
                        },
                        {
                            '_summary'   => 'Plan is 2 assertions',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                        },
                    ],
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => $subtests[0];
                call 'summary'    => 'foo';
                call 'nested'     => 0;
                call 'number'     => 2;
                call 'result'     => object {
                    call 'name'   => 'foo';
                    call 'nested' => 1;
                    call 'total'  => 3;
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => $subtests[1];
                            call 'summary'    => 'foo_nested';
                            call 'nested'     => 1;
                            call 'number'     => 3;
                            call 'result'     => object {
                                call 'name'   => 'foo_nested';
                                call 'nested' => 2;
                                call 'total'  => 2;
                                call 'facts'  => array {
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 1;
                                    };
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 2;
                                    };
                                    item object {
                                        call 'summary'    => 'Plan is 2 assertions';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                    };
                                };
                            };
                        };
                        item {
                            '_summary'   => 'Plan is 3 assertions',
                            'in_subtest' => $subtests[0],
                            'is_subtest' => FDNE,
                            'nested'     => 1,
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Subtest: bar';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Subtest: bar_nested';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Plan is 2 assertions';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
            };
            item object {
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => $subtests[3];
                call 'summary'    => 'Subtest: bar_nested';
                call 'nested'     => 1;
                call 'number'     => 3;
                call 'result'     => object {
                    call 'total'  => 2;
                    call 'nested' => 2;
                    call 'name'   => 'Subtest: bar_nested';
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'summary'    => 'Plan is 2 assertions';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => $subtests[2];
                call 'summary'    => 'Subtest: bar';
                call 'nested'     => 0;
                call 'number'     => 3;
                call 'result'     => object {
                    call 'total'  => 3;
                    call 'nested' => 1;
                    call 'name'   => 'Subtest: bar';
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'summary'    => 'Subtest: bar_nested';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                        };
                        item object {
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => $subtests[3];
                            call 'summary'    => 'Subtest: bar_nested';
                            call 'nested'     => 1;
                            call 'number'     => 3;
                            call 'result'     => object {
                                call 'total'  => 2;
                                call 'nested' => 2;
                                call 'name'   => 'Subtest: bar_nested';
                                call 'facts'  => array {
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 1;
                                    };
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 2;
                                    };
                                    item object {
                                        call 'summary'    => 'Plan is 2 assertions';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                    };
                                };
                            };
                        };
                        item object {
                            call 'summary'    => 'Plan is 3 assertions';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => -1;
                call 'result'     => {
                    'nested' => 0,
                    'total'  => 3,
                };
            };
        },
        "Got all the facts"
    );
};

subtest TAP => sub {
    my @facts;

    my $job = Test2::Harness::Job->new(
        id        => 1,
        file      => "t/subtest_facts/sample.plx",
        listeners => [sub { shift; push @facts => @_ }],
    );

    $job->start(
        runner     => Test2::Harness::Runner->new(),
        start_args => {
            env => {
                'T2_FORMATTER'       => '',
                'HARNESS_IS_VERBOSE' => 1,
            },
            libs     => ['lib', '.'],
            switches => [],
        },
        parser_class => 'Test2::Harness::Parser',
    );

    $job->step until $job->is_done;

    my @subtests = (qw/A C D E B/);

    like(
        \@facts,
        array {
            item {'start'         => 't/subtest_facts/sample.plx'};
            item {'output'        => qr/# Seeded srand with seed '\d+' from local date\./};
            item {'parser_select' => 'Test2::Harness::Parser::TAP'};
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Plan is 2 assertions';
                call 'in_subtest' => $subtests[1];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
            };
            item object {
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => $subtests[1];
                call 'summary'    => 'foo_nested';
                call 'nested'     => 1;
                call 'number'     => 3;
                call 'result'     => {
                    'name'   => 'foo_nested',
                    'nested' => 2,
                    'total'  => 2,
                    'facts'  => [
                        {
                            '_summary'   => 'pass',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                            'number'     => 1,
                        },
                        {
                            '_summary'   => 'pass',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                            'number'     => 2,
                        },
                        {
                            '_summary'   => 'Plan is 2 assertions',
                            'in_subtest' => $subtests[1],
                            'is_subtest' => FDNE,
                            'nested'     => 2,
                        },
                    ],
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => $subtests[0];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => $subtests[0];
                call 'summary'    => 'foo';
                call 'nested'     => 0;
                call 'number'     => 2;
                call 'result'     => object {
                    call 'name'   => 'foo';
                    call 'nested' => 1;
                    call 'total'  => 3;
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'in_subtest' => $subtests[0];
                            call 'is_subtest' => $subtests[1];
                            call 'summary'    => 'foo_nested';
                            call 'nested'     => 1;
                            call 'number'     => 3;
                            call 'result'     => object {
                                call 'name'   => 'foo_nested';
                                call 'nested' => 2;
                                call 'total'  => 2;
                                call 'facts'  => array {
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 1;
                                    };
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 2;
                                    };
                                    item object {
                                        call 'summary'    => 'Plan is 2 assertions';
                                        call 'in_subtest' => $subtests[1];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                    };
                                };
                            };
                        };
                        item {
                            '_summary'   => 'Plan is 3 assertions',
                            'in_subtest' => $subtests[0],
                            'is_subtest' => FDNE,
                            'nested'     => 1,
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Subtest: bar';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Subtest: bar_nested';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 1;
            };
            item object {
                call 'summary'    => 'pass';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
                call 'number'     => 2;
            };
            item object {
                call 'summary'    => 'Plan is 2 assertions';
                call 'in_subtest' => $subtests[3];
                call 'is_subtest' => FDNE;
                call 'nested'     => 2;
            };
            item object {
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => $subtests[3];
                call 'summary'    => 'Subtest: bar_nested';
                call 'nested'     => 1;
                call 'number'     => 3;
                call 'result'     => object {
                    call 'total'  => 2;
                    call 'nested' => 2;
                    call 'name'   => 'Subtest: bar_nested';
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'summary'    => 'Plan is 2 assertions';
                            call 'in_subtest' => $subtests[3];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 2;
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => $subtests[2];
                call 'is_subtest' => FDNE;
                call 'nested'     => 1;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => $subtests[2];
                call 'summary'    => 'Subtest: bar';
                call 'nested'     => 0;
                call 'number'     => 3;
                call 'result'     => object {
                    call 'total'  => 3;
                    call 'nested' => 1;
                    call 'name'   => 'Subtest: bar';
                    call 'facts'  => array {
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 1;
                        };
                        item object {
                            call 'summary'    => 'pass';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                            call 'number'     => 2;
                        };
                        item object {
                            call 'summary'    => 'Subtest: bar_nested';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                        };
                        item object {
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => $subtests[3];
                            call 'summary'    => 'Subtest: bar_nested';
                            call 'nested'     => 1;
                            call 'number'     => 3;
                            call 'result'     => object {
                                call 'total'  => 2;
                                call 'nested' => 2;
                                call 'name'   => 'Subtest: bar_nested';
                                call 'facts'  => array {
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 1;
                                    };
                                    item object {
                                        call 'summary'    => 'pass';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                        call 'number'     => 2;
                                    };
                                    item object {
                                        call 'summary'    => 'Plan is 2 assertions';
                                        call 'in_subtest' => $subtests[3];
                                        call 'is_subtest' => FDNE;
                                        call 'nested'     => 2;
                                    };
                                };
                            };
                        };
                        item object {
                            call 'summary'    => 'Plan is 3 assertions';
                            call 'in_subtest' => $subtests[2];
                            call 'is_subtest' => FDNE;
                            call 'nested'     => 1;
                        };
                    };
                };
            };
            item object {
                call 'summary'    => 'Plan is 3 assertions';
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => 0;
            };
            item object {
                call 'in_subtest' => FDNE;
                call 'is_subtest' => FDNE;
                call 'nested'     => -1;
                call 'result'     => {
                    'nested' => 0,
                    'total'  => 3,
                };
            };

        },
        "Got all the facts"
    );
};

done_testing;
