use Test2::Bundle::Extended -target => 'Test2::Formatter::T2Harness';

BEGIN {
    $INC{'Test/Builder/Formatter.pm'} = __FILE__;
    package Test::Builder::Formatter;
    sub new { bless {}, shift }
}

subtest 'Use EventStream when output is not a terminal' => sub {
    my ($term, $it);
    {
        local *STDOUT;
        open(STDOUT, '>', \(my $foo = "")) or die "could not open fake STDOUT: $!";

        $term = -t STDOUT;
        $it   = Test2::Formatter::T2Harness->new();
    }

    ok(!$term, "STDOUT is not a terminal for the test");
    isa_ok($it, 'Test2::Formatter::EventStream');
};

subtest 'use Test::Builder::Formatter if Test::Builder is loaded' => sub {
    my ($term, $it);
    {
        local $INC{'Test/Builder.pm'} = __FILE__;
        local *STDOUT;
        open(STDOUT, '>', \(my $foo = "")) or die "could not open fake STDOUT: $!";

        $term = -t STDOUT;
        $it   = Test2::Formatter::T2Harness->new();
    }

    ok(!$term, "STDOUT is not a terminal for the test");
    isa_ok($it, 'Test::Builder::Formatter');
};

SKIP: {
    skip "These tests run only in AUTHOR_TESTING"
        unless $ENV{AUTHOR_TESTING};

    my $pty = eval { require IO::Pty; IO::Pty->new };

    skip "These tests require IO::Pty"
        unless $pty && -t $pty;

    my ($term, $it);

    {
        local *STDOUT = $pty;

        $term = -t STDOUT;
        $it   = Test2::Formatter::T2Harness->new();
    }

    subtest 'use TAP if stdout is a terminal' => sub {
        ok($term, "STDOUT is a terminal for the test");
        isa_ok($it, 'Test2::Formatter::TAP');
    };


    {
        local $INC{'Test/Builder.pm'} = __FILE__;
        local *STDOUT = $pty;

        $term = -t STDOUT;
        $it   = Test2::Formatter::T2Harness->new();
    }

    subtest 'use Test::Builder::Formatter if Test::Builder is loaded' => sub {
        ok($term, "STDOUT is a terminal for the test");
        isa_ok($it, 'Test::Builder::Formatter');
    };
}

done_testing;
