use Test2::Bundle::Extended -target => 'Test2::Harness::Parser::EventStream';
use Test2::Event::Ok;

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
        my $self   = shift;
        my %params = @_;

        return shift @stderr unless $params{peek};
        return $stderr[0];
    }

    sub get_out_line {
        my $self   = shift;
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
            call summary     => 'random stderr';
            call diagnostics => T();
        },
        'First stderr'
    );

    is(
        $one->parse_stderr,
        object {
            call summary     => '# TAP diag for some reason';
            call diagnostics => T();
        },
        'TAP diag that should not be here'
    );

    is(
        $one->parse_stderr,
        object {
            call summary     => '# More TAP diag for some reason';
            call diagnostics => T();
        },
        'TAP diag that should not be here (more)'
    );

    is(
        $one->parse_stderr,
        object {
            call summary     => 'random stderr again';
            call diagnostics => T();
        },
        'First stderr'
    );

    is(
        $one->parse_stderr,
        object {
            call summary     => 'random stderr and again';
            call diagnostics => T();
        },
        'First stderr'
    );

    is([$one->parse_stderr], [], 'No more stderr');
};

subtest parse_stdout => sub {
    my $one = $CLASS->new(proc => 'My::Proc', job => 1);

    @stdout = ("random stdout\n");

    is(
        $one->parse_stdout,
        object {
            call summary     => 'random stdout';
            call diagnostics => F();
        },
        'First stdout'
    );

    is([$one->parse_stdout], [], 'No more stdout');

    @stdout = ("T2_ENCODING: foo\r\n");
    is(
        $one->parse_stdout,
        object {
            call encoding => 'foo';
        },
        'Encoding'
    );

    my $event = Test2::Event::Ok->new(
        pass => 1,
        name => 'hello',
    );

    # If we load this early it gets used as the formatter for this .t file.
    require Test2::Formatter::EventStream;
    my $str = 'T2_EVENT: ' . Test2::Formatter::EventStream->_event_to_json($event) . "\r\n";
    @stdout = ($str);

    is(
        [$one->parse_stdout],
        [
            object {
                call name             => 'hello';
                call diagnostics      => F();
                call causes_fail      => F();
                call increments_count => T();
            }
        ],
        'Parsed event'
    );
};

done_testing;
