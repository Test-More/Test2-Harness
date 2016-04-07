use Test2::Bundle::Extended -target => 'Test2::Harness::Fact';

# Make sure it has JSON capabilities.
can_ok($CLASS, qw/JSON/);

can_ok($CLASS, qw{
    stamp
    nested

    diagnostics
    causes_fail
    increments_count
    sets_plan
    in_subtest
    is_subtest
    terminate
    number

    hide
    start
    event
    result
    parse_error
    output
    encoding
    parser_select

    parsed_from_string
    parsed_from_handle

    summary
    set_summary
});

subtest init => sub {
    my $one = $CLASS->new(summary => 'foo');
    isa_ok($one, $CLASS);
    ok($one->stamp, "Got timestamp");
    is($one->summary,  "foo", "got summary");
    is($one->_summary, "foo", "got _summary");
    ok(!$one->{summary}, "kept summary out of the 'summary' key");
};

subtest summary => sub {
    my $fact = $CLASS->new;
    is($fact->summary, 'no summary', "default summary");

    $fact->set_encoding('encoding');
    is($fact->summary, 'encoding', "encoding summary");

    $fact->set_result(mock {name => "result"});
    is($fact->summary, 'result', "used result name");

    $fact->set_output("output");
    is($fact->summary, 'output', "used output as summary");

    $fact->set_parser_select('a parser');
    is($fact->summary, 'a parser', "used parser selection");

    $fact->set_parse_error('parser failed');
    is($fact->summary, 'parser failed', "used parser error");

    $fact->set_start('starting now');
    is($fact->summary, 'starting now', 'used start value');

    $fact->set_summary('a summary');
    is($fact->summary, 'a summary', "used direct summary");
    is($fact->_summary, 'a summary', "set internally");
};

subtest json => sub {
    my $fact = $CLASS->new(
        _summary => 'foo',
        nested => 2,
        diagnostics => 1,
        causes_fail => 0,
        increments_count => 1,
        sets_plan => [2],
        in_subtest => 'abc',
        is_subtest => 'xyz',
        terminate => 0,
        number => 2,
        hide => 0,
        start => 'foo.t',
        event => {a => 1},
        result => undef,
        parse_error => 'an error',
        output => 'foo bar',
        encoding => 'utf8',
        parser_select => 'bleh',
    );

    my $json = $fact->to_json;

    is(
        $CLASS->from_json($json),
        $fact,
        "Got from json"
    );

    is(
        $CLASS->from_string("T2_EVENT: $json", add => 'this'),
        {
            %$fact,
            parsed_from_string => "T2_EVENT: $json",
            add => 'this',
        },
        "Got from string"
    );
};

subtest from_event => sub {
    {
        package Test2::Event::Phony;
        BEGIN { $INC{'Test2/Event/Phony.pm'} = __FILE__ }

        use base 'Test2::Event';
        use Test2::Util::HashBase qw/foo bar baz/;

        sub causes_fail      { 42 }
        sub increments_count { 42 }
        sub diagnostics      { 42 }
        sub no_display       { 42 }
        sub terminate        { 42 }
        sub global           { 42 }
        sub sets_plan        { 42 }
        sub summary          { 42 }
        sub nested           { 42 }
        sub in_subtest       { 42 }
        sub subtest_id       { 43 }
    }

    my $e = Test2::Event::Phony->new(foo => 'a', bar => 'b', baz => { a => 1 });
    is(
        $CLASS->from_event($e, override => 'yes'),
        object {
            prop blessed => 'Test2::Harness::Fact';

            call event => hash {
                field '__PACKAGE__' => 'Test2::Event::Phony';
                field '__FILE__'    => __FILE__;

                field foo => 'a';
                field bar => 'b';
                field baz => {a => 1};

                end;
            };

            field override => 'yes';

            field _summary         => 42;
            field causes_fail      => 42;
            field increments_count => 42;
            field nested           => 42;
            field hide             => 42;
            field diagnostics      => 42;
            field in_subtest       => 42;
            field terminate        => 42;
            field is_subtest       => 43;

            field sets_plan => [42];
        },
        "Got fact, no trace"
    );

    $e->set_trace(Test2::Util::Trace->new(frame => [ 'Foo', 'Foo.t', 42 ]));
    is(
        $CLASS->from_event($e, override => 'yes'),
        object {
            prop blessed => 'Test2::Harness::Fact';

            call event => hash {
                field '__PACKAGE__' => 'Test2::Event::Phony';
                field '__FILE__'    => __FILE__;

                field foo => 'a';
                field bar => 'b';
                field baz => {a => 1};

                field trace => {frame => [ 'Foo', 'Foo.t', 42 ], __PACKAGE__ => 'Test2::Util::Trace', pid => $$, tid => D()};

                end;
            };

            field override => 'yes';

            field _summary         => 42;
            field causes_fail      => 42;
            field increments_count => 42;
            field nested           => 42;
            field hide             => 42;
            field diagnostics      => 42;
            field in_subtest       => 42;
            field terminate        => 42;
            field is_subtest       => 43;

            field sets_plan => [42];
        },
        "Got fact, with trace"
    );
};

subtest from_result => sub {
    is(
        $CLASS->from_result(
            mock {
                nested     => 5,
                in_subtest => 'foo',
                is_subtest => 'bar',
                passed     => 1,
            }
        ),
        object {
            nested      => 5,
            in_subtest  => 'foo',
            is_subtest  => 'bar',
            causes_fail => 0,
        },
        "Created fact from result"
    );
    is(
        $CLASS->from_result(
            mock {
                nested     => undef,
                in_subtest => undef,
                is_subtest => undef,
                passed     => undef,
            }
        ),
        object {
            nested      => 0,
            in_subtest  => undef,
            is_subtest  => undef,
            causes_fail => 1,
        },
        "Created fact from bad result"
    );
};

done_testing;
