use Test2::Bundle::Extended -target => 'Test2::Harness::Parser';
use Test2::Event::Generic;

can_ok($CLASS, qw/proc job morph step init/);

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

subtest step => sub {
    my @out;
    my @err;
    my $proc = mock {} => (
        add => [
            "get_out_line" => sub { shift; my %params = @_; $params{peek} ? $out[0] : shift @out },
            "get_err_line" => sub { shift; my %params = @_; $params{peek} ? $err[0] : shift @err },
        ]
    );

    my $parser = $CLASS->new(job => 1, proc => $proc);
    push @out => "ok 1 - foo\n";
    is(
        [$parser->step],
        array {
            item 0 => object {
                call parser_class => 'Test2::Harness::Parser::TAP';
            };
            end;
        },
        'selected TAP'
    );
    isa_ok($parser, 'Test2::Harness::Parser::TAP');
    is($proc->get_out_line, "ok 1 - foo\n", 'kept TAP line to parse later');

    $parser = $CLASS->new(job => 1, proc => $proc);
    push @out => "T2_FORMATTER: EventStream\n";
    is(
        [$parser->step],
        array {
            item 0 => object {
                call parser_class => 'Test2::Harness::Parser::EventStream';
            };
            end;
        },
        'selected EventStream'
    );
    isa_ok($parser, 'Test2::Harness::Parser::EventStream');
    is($proc->get_out_line, undef, 'output line was stripped');

    $parser = $CLASS->new(job => 1, proc => $proc);
    push @out => 'will not morph';
    like(
        dies { $parser->step },
        qr/You cannot use Test2::Harness::Parser itself, it must be subclassed/,
        'parser dies when step method cannot morph into a subclass'
    );
};

done_testing;
