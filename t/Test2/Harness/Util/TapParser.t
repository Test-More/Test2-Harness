use Test2::V0 -target => 'Test2::Harness::Util::TapParser';

use ok $CLASS => qw/parse_stdout_tap parse_stderr_tap/;

imported_ok qw/parse_stdout_tap parse_stderr_tap/;

subtest parse_stderr_integration => sub {
    ok(!parse_stderr_tap("foo bar baz"), "TAP stderr must start with a '#'");

    is(
        parse_stderr_tap("# foo"),
        {
            trace => {nested => 0},
            info  => [
                {
                    debug   => 1,
                    details => 'foo',
                    tag     => 'DIAG',
                }
            ],
            from_tap => {
                details => '# foo',
                source  => 'STDERR',
            },
        },
        "Got expected facets for diag"
    );

    is(
        parse_stderr_tap("    # foo"),
        {
            trace => {nested => 1},
            info  => [
                {
                    debug   => 1,
                    details => 'foo',
                    tag     => 'DIAG',
                }
            ],
            from_tap => {
                details => '    # foo',
                source  => 'STDERR',
            },
        },
        "Got expected facets for indented diag"
    );
};

subtest parse_stdout_tap_integration => sub {
    ok(!parse_stdout_tap("foo"), "Not everything is TAP");

    is(
        parse_stdout_tap("# A comment"),
        {
            trace => {nested => 0},
            info  => [
                {
                    debug   => 0,
                    details => 'A comment',
                    tag     => 'NOTE',
                }
            ],
            from_tap => {
                details => '# A comment',
                source  => 'STDOUT',
            },
        },
        "Got expected facets for a comment"
    );

    is(
        parse_stdout_tap('TAP version 42'),
        {
            trace => {nested => 0},
            from_tap => {
                details => 'TAP version 42',
                source  => 'STDOUT',
            },
            about => {details => 'TAP version 42'},
            info =>[{tag => 'INFO', details => 'TAP version 42', debug => FDNE}],
        },
        "Parsed TAP version"
    );

    subtest plan => sub {
        is(
            parse_stdout_tap('1..5'),
            {
                trace    => {nested => 0},
                from_tap => { details => '1..5', source  => 'STDOUT' },
                plan => {count => 5, skip => FDNE, details => FDNE},
            },
            "Parsed the plan"
        );

        is(
            parse_stdout_tap('1..0'),
            {
                trace    => {nested => 0},
                from_tap => { details => '1..0', source  => 'STDOUT' },
                plan => {count => 0, skip => 1, details => 'no reason given'},
            },
            "Parsed the skip plan"
        );

        is(
            parse_stdout_tap('1..0 # SKIP foo bar baz'),
            {
                trace    => {nested => 0},
                from_tap => { details => '1..0 # SKIP foo bar baz', source  => 'STDOUT' },
                plan => {count => 0, skip => 1, details => 'foo bar baz'},
            },
            "Parsed the skip + reason plan"
        );
    };

    my @conds = (
        {nest => 0, prefix => '',         bs => '', pass => T},
        {nest => 1, prefix => '    ',     bs => '', pass => T},
        {nest => 0, prefix => 'not ',     bs => '', pass => F},
        {nest => 1, prefix => '    not ', bs => '', pass => F},
        {nest => 0, prefix => '',         bs => ' { ', pass => T},
        {nest => 1, prefix => '    ',     bs => ' { ', pass => T},
        {nest => 0, prefix => 'not ',     bs => ' { ', pass => F},
        {nest => 1, prefix => '    not ', bs => ' { ', pass => F},
    );

    subtest "$_->{prefix}ok" => sub {
        my $prefix = $_->{prefix};
        my $nest   = $_->{nest};
        my $pass   = $_->{pass};
        my $bs     = $_->{bs};

        my %common = (
            from_tap => T(),
            trace    => {nested => $nest},
            $bs ? (parent => {details => E}, harness => {subtest_start => 1}) : (),
        );

        is(
            parse_stdout_tap("${prefix}ok$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for plain '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok -$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for plain '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok 1$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => 1,
                },
            },
            "Got expected facets for numbered '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 1 -$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => '',
                    no_debug => 1,
                    number   => 1,
                },
            },
            "Got expected facets for numbered '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok foo $bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for named '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
            },
            "Got expected facets for named and numbered '${prefix}ok$bs'"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
            },
            "Got expected facets for named and numbered '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok - foo$bs"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => FDNE,
                },
            },
            "Got expected facets for named '${prefix}ok$bs' with dash"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# TODO"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'TODO', details => ''},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with odo"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo$bs # TODO xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'TODO', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with todo and reason"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# SKIP"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => ''},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with skip"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# SKIP xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with skip and reason"
        );

        is(
            parse_stdout_tap("${prefix}ok 2 - foo $bs# TODO & SKIP xxx"),
            {
                %common,
                assert => {
                    pass     => $pass,
                    details  => 'foo',
                    no_debug => 1,
                    number   => 2,
                },
                amnesty => [
                    {tag => 'SKIP', details => 'xxx'},
                    {tag => 'TODO', details => 'xxx'},
                ],
            },
            "Got expected facets for '${prefix}ok$bs' with todo+skip and reason"
        );
    } for @conds;
};

subtest parse_tap_buffered_subtest => sub {
    is(
        $CLASS->parse_tap_buffered_subtest('ok {'),
        {
            %{$CLASS->parse_tap_ok('ok')},
            parent => { details => '' },
            harness => { subtest_start => 1 },
        },
        "Simple bufferd subtest"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 {'),
        {
            %{$CLASS->parse_tap_ok('ok 1')},
            parent => { details => '' },
            harness => { subtest_start => 1 },
        },
        "Simple bufferd subtest with number"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 - foo {'),
        {
            %{$CLASS->parse_tap_ok('ok 1 - foo')},
            parent => { details => 'foo' },
            harness => { subtest_start => 1 },
        },
        "Simple bufferd subtest with number and name"
    );

    is(
        $CLASS->parse_tap_buffered_subtest('ok 1 - foo { # TODO foo bar baz'),
        {
            %{$CLASS->parse_tap_ok('ok 1 - foo # TODO foo bar baz')},
            parent => { details => 'foo' },
            harness => { subtest_start => 1 },
        },
        "Simple bufferd subtest with number and name and directive"
    );
};

subtest parse_tap_ok => sub {
    ok(1, 'todo');
};

done_testing;

__END__

sub parse_tap_ok {
    my $class = shift;
    my ($line) = @_;

    my ($pass, $todo, $skip, $num, @errors);

    return undef unless $line =~ s/^(not )?ok\b//;
    $pass = !$1;

    push @errors => "'ok' is not immediately followed by a space."
        if $line && !($line =~ m/^ /);

    if ($line =~ s/^(\s*)(\d+)\b//) {
        my $space = $1;
        $num = $2;

        push @errors => "Extra space after 'ok'"
            if length($space) > 1;
    }

    # Not strictly compliant, but compliant with what Test-Simple does...
    # Standard does not have a todo & skip.
    if ($line =~ s/#\s*(todo & skip|todo|skip)(.*)$//i) {
        my ($directive, $reason) = ($1, $2);

        push @errors => "No space before the '#' for the '$directive' directive."
            unless $line =~ s/\s+$//;

        push @errors => "No space between '$directive' directive and reason."
            if $reason && !($reason =~ s/^\s+//);

        $skip = $reason if $directive =~ m/skip/i;
        $todo = $reason if $directive =~ m/todo/i;
    }

    # Standard says that everything after the ok (except the number) is part of
    # the name. Most things add a dash between them, and I am deviating from
    # standards by stripping it and surrounding whitespace.
    $line =~ s/\s*-\s*//;

    $line =~ s/^\s+//;
    $line =~ s/\s+$//;

    my $is_subtest = ($line =~ m/^Subtest:\s*(.*)$/) ? ($1 or 1) : undef;

    my $facet_data = {
        assert => {
            pass     => $pass,
            no_debug => 1,
            details  => $line,
            defined $num ? (number => $num) : (),
        },
    };

    $facet_data->{parent} = {
        details => $is_subtest,
    } if defined $is_subtest;

    push @{$facet_data->{amnesty}} => {
        tag     => 'SKIP',
        details => $skip,
    } if defined $skip;

    push @{$facet_data->{amnesty}} => {
        tag     => 'TODO',
        details => $todo,
    } if defined $todo;

    push @{$facet_data->{info}} => {
        details => $_,
        debug => 1,
        tag => 'PARSER',
    } for @errors;

    return $facet_data;
}

sub parse_tap_version {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^TAP version\s/;

    return {
        about => {
            details => $line,
        },
        info => [
            {
                tag     => 'INFO',
                debug   => 0,
                details => $line,
            }
        ],
    };
}

sub parse_tap_plan {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ s/^1\.\.(\d+)//;
    my $max = $1;

    my ($directive, $reason);

    if ($max == 0) {
        if ($line =~ s/^\s*#\s*//) {
            if ($line =~ s/^(skip)\S*\s*//i) {
                $directive = uc($1);
                $reason = $line;
                $line = "";
            }
        }

        $directive ||= "SKIP";
        $reason    ||= "no reason given";
    }

    my $facet_data = {
        plan => {
            count   => $max,
            skip    => ($directive && $directive eq 'SKIP') ? 1 : 0,
            details => $reason,
        }
    };

    push @{$facet_data->{info}} => {
        details => 'Extra characters after plan.',
        debug => 1,
        tag => 'PARSER',
    } if $line =~ m/\S/;

    return $facet_data;
}

sub parse_tap_bail {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^Bail out!\s*(.*)$/;

    return {
        control => {
            halt => 1,
            details => $1,
        }
    };
}

sub parse_tap_comment {
    my $class = shift;
    my ($line) = @_;

    return undef unless $line =~ m/^#/;

    $line =~ s/^#\s*//msg;

    return {
        info => [
            {
                details => $line,
                tag     => 'NOTE',
                debug   => 0,
            }
        ]
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::TapParser - Produce EventFacets from a line of TAP.

=head1 DESCRIPTION

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
