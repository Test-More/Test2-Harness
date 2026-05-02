use Test2::V0;

# Unit tests for the pure-helper module Test2::Harness2::Collector::Util.

use Test2::Harness2::Collector::Util qw{
    spec_class
    validate_spec
    make_warn_handler
    win32_quote_arg
};

# ---------------------------------------------------------------------------
# spec_class
# ---------------------------------------------------------------------------

subtest 'spec_class - bare class name' => sub {
    is(spec_class('Foo::Bar'), 'Foo::Bar', 'string spec returns itself');
};

subtest 'spec_class - arrayref [class, @args]' => sub {
    is(spec_class(['Foo::Bar', x => 1]), 'Foo::Bar', 'first element returned');
};

subtest 'spec_class - blessed instance' => sub {
    my $obj = bless {}, 'Foo::Bar';
    is(spec_class($obj), 'Foo::Bar', 'ref() of blessed object returned');
};

subtest 'spec_class - other refs return undef' => sub {
    is(spec_class({foo => 1}), undef, 'hashref returns undef');
    is(spec_class(\my $scalar), undef, 'scalar ref returns undef');
};

# ---------------------------------------------------------------------------
# validate_spec - role enforcement
# ---------------------------------------------------------------------------

# Build a tiny role + an implementing class + a non-implementing class,
# all on the fly, to drive validate_spec without pulling in heavyweight
# Test2::Harness2 modules.
{

    package T2H2Test::Util::FakeRole;
    use Role::Tiny;
    requires 'do_thing';
}

{

    package T2H2Test::Util::Implementer;
    use Role::Tiny::With;
    sub new { bless {}, shift }
    sub do_thing { 1 }
    with 'T2H2Test::Util::FakeRole';
}

{

    package T2H2Test::Util::NonImplementer;
    sub new { bless {}, shift }
}

subtest 'validate_spec - bare class name implementing role' => sub {
    my $ok = eval {
        validate_spec('T2H2Test::Util::Implementer', 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    ok($ok, 'validate_spec accepts implementer');
};

subtest 'validate_spec - blessed instance implementing role' => sub {
    my $obj = T2H2Test::Util::Implementer->new;
    my $ok  = eval {
        validate_spec($obj, 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    ok($ok, 'validate_spec accepts implementer instance');
};

subtest 'validate_spec - arrayref [class, @args] implementing role' => sub {
    my $ok = eval {
        validate_spec(['T2H2Test::Util::Implementer'], 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    ok($ok, 'validate_spec accepts arrayref form');
};

subtest 'validate_spec - non-implementer class is rejected' => sub {
    my $ok  = eval {
        validate_spec('T2H2Test::Util::NonImplementer', 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    my $err = $@;
    ok(!$ok, 'rejects non-implementer');
    like($err, qr/does not implement T2H2Test::Util::FakeRole/, 'error names the role');
};

subtest 'validate_spec - blessed non-implementer rejected' => sub {
    my $obj = T2H2Test::Util::NonImplementer->new;
    my $ok  = eval {
        validate_spec($obj, 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    my $err = $@;
    ok(!$ok, 'rejects blessed non-implementer');
    like($err, qr/does not implement T2H2Test::Util::FakeRole/, 'error names the role');
};

subtest 'validate_spec - arrayref with non-class first element rejected' => sub {
    my $ok  = eval {
        validate_spec([{}], 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    my $err = $@;
    ok(!$ok, 'rejects arrayref with non-string first element');
    like($err, qr/arrayref must begin with a class name/, 'error is descriptive');
};

subtest 'validate_spec - hashref spec rejected' => sub {
    my $ok  = eval {
        validate_spec({foo => 1}, 'thing', 'T2H2Test::Util::FakeRole');
        1;
    };
    my $err = $@;
    ok(!$ok, 'rejects hashref spec');
    like($err, qr/Invalid thing specification/, 'error is descriptive');
};

# ---------------------------------------------------------------------------
# make_warn_handler
# ---------------------------------------------------------------------------

subtest 'make_warn_handler - dispatches each warning as a Test2::Harness2::Event' => sub {
    require Test2::Harness2::Event;

    my @events;
    my $cb      = sub { push @events => $_[0] };
    my $handler = make_warn_handler($cb);

    is(ref($handler), 'CODE', 'returns a coderef');

    $handler->("first warning\n");
    $handler->("second warning\n");

    is(scalar @events, 2, 'each warning produced one event');

    isa_ok($events[0], 'Test2::Harness2::Event');
    is(
        $events[0]->{facet_data}->{info}->[0],
        {tag => 'WARNING', details => "first warning\n", debug => 1},
        'first event carries the WARNING info facet',
    );
    is(
        $events[1]->{facet_data}->{info}->[0]->{details},
        "second warning\n",
        'second event carries the second warning text',
    );
};

subtest 'make_warn_handler - callback exception falls back to STDERR' => sub {
    my $bad     = sub { die "boom\n" };
    my $handler = make_warn_handler($bad);

    my $stderr = '';
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "open: $!";
        $handler->("a warning\n");
    }

    like($stderr, qr/Failed to log warning event/, 'fallback message printed');
    like($stderr, qr/a warning/,                    'fallback includes the original warning text');
};

subtest 'make_warn_handler - requires a CODE ref' => sub {
    my $ok  = eval { make_warn_handler('not a coderef'); 1 };
    my $err = $@;
    ok(!$ok, 'rejects non-CODE callback');
    like($err, qr/requires a callback/, 'error is descriptive');
};

# ---------------------------------------------------------------------------
# win32_quote_arg
# ---------------------------------------------------------------------------

subtest 'win32_quote_arg - bare argument passes through' => sub {
    is(win32_quote_arg('perl'),     'perl',     'plain string unchanged');
    is(win32_quote_arg('--flag=1'), '--flag=1', 'flag-style unchanged');
};

subtest 'win32_quote_arg - argument with spaces wrapped' => sub {
    is(win32_quote_arg('Program Files'), '"Program Files"', 'spaces wrapped');
    is(win32_quote_arg("a\tb"),          qq{"a\tb"},        'tab triggers wrapping');
};

subtest 'win32_quote_arg - embedded double-quote escaped' => sub {
    is(win32_quote_arg('say "hi"'), '"say \"hi\""', 'embedded quotes escaped');
};

# ---------------------------------------------------------------------------
# FileLineReader
# ---------------------------------------------------------------------------

subtest 'FileLineReader - reads lines and emits trailing undef on EOF' => sub {
    my $text = "first\nsecond\nthird\n";
    open(my $fh, '<', \$text) or die "open: $!";

    my $r = Test2::Harness2::Collector::Util::FileLineReader->new($fh);

    my @items = $r->read_lines;
    is(
        \@items,
        [
            [line => 'first'],
            [line => 'second'],
            [line => 'third'],
            undef,
        ],
        'all three lines plus EOF sentinel',
    );

    is([$r->read_lines], [], 'subsequent reads are empty after EOF');
};

done_testing;
