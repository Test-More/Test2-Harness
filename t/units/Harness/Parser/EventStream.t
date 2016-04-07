use Test2::Bundle::Extended -target => 'Test2::Harness::Parser::EventStream';

isa_ok($CLASS, 'Test2::Harness::Parser');
can_ok($CLASS, qw/morph step parse_stderr parse_stdout/);

subtest step => sub {
    my $m = mock $CLASS => (
        override => [
            parse_stderr => sub { 'stderr' },
            parse_stdout => sub { 'stdout' },
        ],
    );

    my $one = $CLASS->new(job => 1, proc => 1);

    is(
        [$one->step],
        ['stderr', 'stdout'],
        "ran parse_stderr and parse_stdout, returned the results from both as a list"
    );
};

my (@stderr, @stdout, $done, $encoding);
{
    package My::Proc;

    sub is_done { $done }

    sub encoding { $encoding = pop }

    sub get_err_line {
        my $self = shift;
        my %params = @_;

        return shift @stderr unless $params{peek};
        return $stderr[0];
    }

    sub get_out_line {
        my $self = shift;
        my %params = @_;

        return shift @stdout unless $params{peek};
        return $stdout[0];
    }
}

subtest parse_stderr => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stderr = (
        "random stderr\n",
        "# TAP diag for some reason\n",
        "# More TAP diag for some reason\n",
        "random stderr again\n",
        "random stderr and again\n",
    );

    is(
        $one->parse_stderr,
        object {
            call summary            => "random stderr";
            call parsed_from_string => "random stderr\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "First stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call summary            => "# TAP diag for some reason";
            call parsed_from_string => "# TAP diag for some reason\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "TAP diag that should not be here"
    );

    is(
        $one->parse_stderr,
        object {
            call summary            => "# More TAP diag for some reason";
            call parsed_from_string => "# More TAP diag for some reason\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "TAP diag that should not be here (more)"
    );

    is(
        $one->parse_stderr,
        object {
            call summary            => "random stderr again";
            call parsed_from_string => "random stderr again\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "First stderr"
    );

    is(
        $one->parse_stderr,
        object {
            call summary            => "random stderr and again";
            call parsed_from_string => "random stderr and again\n";
            call parsed_from_handle => 'STDERR';
            call diagnostics        => 1;
        },
        "First stderr"
    );

    is([$one->parse_stderr], [], "No more stderr");
};

subtest parse_stdout => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = ( "random stdout\n" );

    is(
        $one->parse_stdout,
        object {
            call summary            => "random stdout";
            call parsed_from_string => "random stdout\n";
            call parsed_from_handle => 'STDOUT';
            call diagnostics        => 0;
        },
        "First stdout"
    );

    is([$one->parse_stdout], [], "No more stdout");

    @stdout = ( "T2_ENCODING: foo\r\n" );
    is(
        $one->parse_stdout,
        object {
            call encoding => 'foo';
            call parsed_from_string => "T2_ENCODING: foo\r\n";
            call parsed_from_handle => 'STDOUT';
        },
        "Encoding"
    );

    my $fact = Test2::Harness::Fact->new(
        output           => 'hello',
        diagnostics      => 1,
        event            => {a => 1},
        causes_fail      => 0,
        increments_count => 1,
    );
    my $str = "T2_EVENT: " . $fact->to_json . "\r\n";
    @stdout = ( $str );

    is(
        [$one->parse_stdout],
        [
            object {
                call output             => 'hello';
                call parsed_from_handle => 'STDOUT';
                call diagnostics        => 1;
                call event              => {a => 1};
                call causes_fail        => 0;
                call increments_count   => 1;
            }
        ],
        "Parsed event"
    );
};

done_testing;
