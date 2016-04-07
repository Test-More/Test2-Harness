use Test2::Bundle::Extended -target => 'Test2::Harness::Parser';

can_ok($CLASS, qw/proc job morph step init parse_line parse_stderr parse_stdout/);

subtest init => sub {
    like(
        dies { $CLASS->new() },
        qr/'proc' is a required attribute/,
        "'proc' is required"
    );

    like(
        dies { $CLASS->new(proc => 1) },
        qr/'job' is a required attribute/,
        "'job' is required"
    );

    my $morph = 0;
    my $m = mock $CLASS => ( override => [ morph => sub { $morph++ } ] );
    $CLASS->new(job => 1, proc => 1);
    is($morph, 1, "init calls morph");
};

subtest parse_line => sub {
    my $one = $CLASS->new(job => 1, proc => 1);

    like(
        $one->parse_line(STDOUT => "foo bar baz\n"),
        object {
            prop blessed => 'Test2::Harness::Fact';

            call output             => "foo bar baz";
            call parsed_from_handle => 'STDOUT';
            call parsed_from_string => "foo bar baz\n";
            call diagnostics        => 0,
        },
        "Got a fact from STDOUT"
    );

    like(
        $one->parse_line(STDERR => "foo\nbar baz\n"),
        object {
            prop blessed => 'Test2::Harness::Fact';

            call output             => "foo\nbar baz";
            call parsed_from_handle => 'STDERR';
            call parsed_from_string => "foo\nbar baz\n";
            call diagnostics        => 1,
        },
        "Got a fact from STDERR"
    );
};

for my $io (qw/out err/) {
    my $m = "parse_std$io";
    subtest $m => sub {
        my @out = ( "hi\n", 'bye' );
        my $proc = mock {} => ( add => [ "get_${io}_line" => sub { shift @out } ] );
        my $parser = $CLASS->new(job => 1, proc => $proc);

        is(
            $parser->$m,
            object {
                output => 'hi',
                parsed_from_handle => uc("STD$io"),
            },
            "Got first fact"
        );

        is(
            $parser->$m,
            object {
                output => 'bye',
                parsed_from_handle => uc("STD$io"),
            },
            "Got second fact"
        );
    };
}

subtest step => sub {
    my @out = ( "hi\n" );
    my @err = ( "oops\n" );
    my $proc = mock {} => (
        add => [
            "get_out_line" => sub { shift; my %params = @_; $params{peek} ? $out[-1] : shift @out },
            "get_err_line" => sub { shift; my %params = @_; $params{peek} ? $err[-1] : shift @err },
        ]
    );
    my $parser = $CLASS->new(job => 1, proc => $proc);

    like([$parser->step], [{output => 'hi'}], "got 'hi'");
    like([$parser->step], [], "nothing");

    $proc->is_done(1);
    like([$parser->step], [{output => 'oops'}], "stderr");

    $proc->is_done(0);
    $parser = $CLASS->new(job => 1, proc => $proc);
    push @out => "ok 1 - foo\n";
    like([$parser->step], [{parser_select => 'Test2::Harness::Parser::TAP'}], "selected TAP");
    isa_ok($parser, 'Test2::Harness::Parser::TAP');
    is($proc->get_out_line, "ok 1 - foo\n", "kept TAP line to parse later");

    $parser = $CLASS->new(job => 1, proc => $proc);
    push @out => "T2_FORMATTER: EventStream\n";
    like([$parser->step], [{parser_select => 'Test2::Harness::Parser::EventStream'}], "selected EventStream");
    isa_ok($parser, 'Test2::Harness::Parser::EventStream');
    is($proc->get_out_line, undef, "output line was stripped");
};

done_testing;
