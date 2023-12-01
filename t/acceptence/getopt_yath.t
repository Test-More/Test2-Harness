use Test2::V0 -target => 'Getopt::Yath';

use Getopt::Yath;

imported_ok qw/options option include_options option_post_process option_group parse_options/;

delete $ENV{EXAMPLEA};
delete $ENV{EXAMPLEB};
delete $ENV{EXAMPLEC};

option_group {category => 'This is the category', group => 'foo', no_module => 1} => sub {
    like(
        dies { parse_options(['--xyz']) },
        qr/'--xyz' is not a valid option\./,
        "Cannot use an invalid option",
    );

    ok(
        lives { parse_options(['--xyz'], skip_invalid_opts => 1) },
        "Skip invalid",
    );

    subtest Bool => sub {
        my $trigger = 0;
        option foo => (
            type    => 'Bool',
            short   => 'f',
            default => 1,
            description => 'foo boolean',
            trigger => sub { $trigger++ }
        );
        like(
            parse_options([]),
            {settings => {foo => {foo => 1}}},
            "A bool with a default of 1 and nothing provided"
        );
        is($trigger, 0, "Not triggered"); $trigger = 0;
        like(
            parse_options(['--foo']),
            {settings => {foo => {foo => 1}}},
            "Parsed a bool with a default of 1 turned on"
        );
        is($trigger, 1, "triggered"); $trigger = 0;
        like(
            parse_options(['-f']),
            {settings => {foo => {foo => 1}}},
            "Parsed a bool with a default of 1 turned on"
        );
        is($trigger, 1, "triggered"); $trigger = 0;
        like(
            dies { parse_options(['-f=0']) },
            qr/Use of 'arg=val' form is not allowed in option '-f=0'\. Arguments are not allowed for this option type\./,
            "Boolean types do not allow an argument"
        );
        is($trigger, 0, "not triggered"); $trigger = 0;
        like(
            parse_options(['--no-foo']),
            {settings => {foo => {foo => 0}}},
            "Parsed a bool with a default of 1 turned off"
        );
        is($trigger, 1, "triggered"); $trigger = 0;

        option bar => (
            type    => 'Bool',
            default => 0,
            description => 'bar boolean',
        );
        like(
            parse_options([]),
            {settings => {foo => {bar => 0}}},
            "A bool with a default of 0 and nothing provided"
        );
        like(
            parse_options(['--bar']),
            {settings => {foo => {bar => 1}}},
            "Parsed a bool with a default of 0 turned on"
        );
        like(
            parse_options(['--no-bar']),
            {settings => {foo => {bar => 0}}},
            "Parsed a bool with a default of 0 turned off"
        );

        option baz => (
            type => 'Bool',
            description => 'baz boolean',
        );
        like(
            parse_options([]),
            {settings => {foo => {baz => 0}}},
            "A bool with no default and nothing provided"
        );
        like(
            parse_options(['--baz']),
            {settings => {foo => {baz => 1}}},
            "Parsed a bool with no default, turned on"
        );
        like(
            parse_options(['--no-baz']),
            {settings => {foo => {baz => 0}}},
            "Parsed a bool with no default, turned off"
        );
    };

    subtest Count => sub {
        option cnt => (
            type => 'Count',
            short => 'c',
            alt => ['count'],
            initialize => 2,
            description => 'A counter',
        );
        like(
            parse_options([]),
            {settings => {foo => {cnt => 2}}},
            "Nothing provided, initialized to 2"
        );
        like(
            parse_options(['--no-count']),
            {settings => {foo => {cnt => 0}}},
            "disabled via --no-count"
        );
        like(
            parse_options(['--no-count', '-ccc']),
            {settings => {foo => {cnt => 3}}},
            "disabled via --no-count, but then seen 3 times as short value"
        );

        like(
            parse_options(['--no-count', '-cc', '-c=-1']),
            {settings => {foo => {cnt => -1}}},
            "disabled via --no-count, but then seen 2 times as short value, but last one sets a specific value"
        );

        like(
            parse_options(['-c=5', '--count', '-c']),
            {settings => {foo => {cnt => 7}}},
            "Set a value, then add 2 more"
        );

        like(
            parse_options(['-c=0']),
            {settings => {foo => {cnt => 0}}},
            "Set to 0"
        );
    };

    subtest Scalar => sub {
        option scl => (
            type => 'Scalar',
            short => 's',
            alt => ['scalar'],
            default => 'I am a scalar',
            description => 'A scalar',
        );

        like(
            parse_options([]),
            {settings => {foo => {scl => 'I am a scalar'}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-s' => 'foo']),
            {settings => {foo => {scl => 'foo'}}},
            "set to foo, short form"
        );
        like(
            parse_options(['-s=foo']),
            {settings => {foo => {scl => 'foo'}}},
            "set to foo, short assign form"
        );
        like(
            parse_options(['--scl' => 'foo']),
            {settings => {foo => {scl => 'foo'}}},
            "set to foo, long form"
        );
        like(
            parse_options(['--scalar=foo']),
            {settings => {foo => {scl => 'foo'}}},
            "set to foo, long assign form"
        );
        like(
            dies { parse_options(['--scalar']) },
            qr/No argument provided to '--scalar'\./,
            "Need a value"
        );
        like(
            parse_options(['--no-scalar']),
            {settings => {foo => {scl => undef}}},
            "Disabled"
        );

        option scl2 => (
            type => 'Scalar',
            description => 'Another scalar',
        );
        like(
            parse_options([]),
            {settings => {foo => {scl2 => undef}}},
            "Nothing provided, default to undef"
        );
    };

    subtest Auto => sub {
        option aut => (
            type => 'Auto',
            short => 'a',
            alt => ['auto'],
            autofill => 'xxx',
            default => 'yyy',
            description => 'An auto-field',
        );

        like(
            parse_options([]),
            {settings => {foo => {aut => 'yyy'}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-a']),
            {settings => {foo => {aut => 'xxx'}}},
            "Short with no arg, use autofill"
        );
        like(
            parse_options(['-afub']),
            {settings => {foo => {aut => 'fub'}}},
            "Short with arg, no space and no ="
        );
        like(
            parse_options(['-a=foo']),
            {settings => {foo => {aut => 'foo'}}},
            "Short with arg"
        );
        like(
            parse_options(['--no-aut']),
            {settings => {foo => {aut => undef}}},
            "--no form"
        );
        like(
            parse_options(['--aut', 'foo'], skip_non_opts => 1),
            {settings => {foo => {aut => 'xxx'}}, skipped => ['foo']},
            "Does not slurp next arg"
        );

        option aut2 => ( type => 'Auto', autofill => 'zzz' );
        like(
            parse_options([]),
            {settings => {foo => {aut2 => undef}}},
            "Nothing provided"
        );

        like(
            dies { option aut3 => ( type => 'Auto' ) },
            qr/'autofill' is required/,
            "autofill is required for auto type"
        );
    };

    subtest Map => sub {
        option map => (
            type => 'Map',
            short => 'm',
            default => sub { 'yyy' => 'xxx' },
            split_on => ',',
            description => 'A map',
        );
        like(
            parse_options([]),
            {settings => {foo => {map => {'yyy' => 'xxx'}}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-m' => 'foo=bar']),
            {settings => {foo => {map => {'foo' => 'bar'}}}},
            "Specified a value"
        );
        like(
            parse_options(['-m=foo=bar']),
            {settings => {foo => {map => {'foo' => 'bar'}}}},
            "Specified a value with ="
        );
        like(
            parse_options(['-mfoo=bar']),
            {settings => {foo => {map => {'foo' => 'bar'}}}},
            "Specified a value with no gap"
        );
        like(
            parse_options(['-m' => 'foo=bar,baz=bat', '--map' => 'fruit=pear']),
            {settings => {foo => {map => {'foo' => 'bar', 'baz' => 'bat', 'fruit' => 'pear'}}}},
            "Specified multiple values"
        );
        like(
            parse_options(['--no-map']),
            {settings => {foo => {map => {}}}},
            "Cleared values"
        );
    };

    subtest AutoMap => sub {
        option auto_map => (
            type => 'AutoMap',
            short => 'A',
            autofill => sub { 'aaa' => 'bbb' },
            default => sub { 'yyy' => 'xxx' },
            split_on => ',',
            description => 'An Auto map',
        );
        like(
            parse_options([]),
            {settings => {foo => {auto_map => {'yyy' => 'xxx'}}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-A']),
            {settings => {foo => {auto_map => {'aaa' => 'bbb'}}}},
            "Option, but no value, autofill"
        );
        like(
            parse_options(['-A=foo=bar']),
            {settings => {foo => {auto_map => {'foo' => 'bar'}}}},
            "Specified a value"
        );
        like(
            dies { parse_options(['-A', 'foo=bar']) },
            qr/'foo=bar' is not a valid option\./,
            "Do not slurp value after space"
        );
        like(
            parse_options(['-A=foo=bar,baz=bat', '--auto-map=fruit=pear']),
            {settings => {foo => {auto_map => {'foo' => 'bar', 'baz' => 'bat', 'fruit' => 'pear'}}}},
            "Specified multiple values"
        );
        like(
            parse_options(['--no-auto-map']),
            {settings => {foo => {auto_map => {}}}},
            "Cleared values"
        );
    };

    subtest List => sub {
        option list => (
            type => 'List',
            short => 'l',
            default => sub { qw/foo bar baz/ },
            split_on => ',',
            description => 'a list',
        );
        like(
            parse_options([]),
            {settings => {foo => {list => [qw/foo bar baz/]}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-l' => 'xxx']),
            {settings => {foo => {list => ['xxx']}}},
            "Specified a value"
        );
        like(
            parse_options(['-l' => 'xxx,yyy,baz,bat', '--list' => 'fruit,pear', '-l=bob']),
            {settings => {foo => {list => ['xxx', 'yyy', 'baz', 'bat', 'fruit','pear','bob']}}},
            "Specified multiple values"
        );
        like(
            parse_options(['--no-list']),
            {settings => {foo => {list => []}}},
            "Cleared values"
        );
    };

    subtest AutoList => sub {
        option auto_list => (
            type => 'AutoList',
            short => 'L',
            default => sub { qw/foo bar baz/ },
            autofill => sub { qw/xxx yyy zzz/ },
            split_on => ',',
            description => 'an auto list',
        );
        like(
            parse_options([]),
            {settings => {foo => {auto_list => [qw/foo bar baz/]}}},
            "Nothing provided, default used"
        );
        like(
            parse_options(['-L']),
            {settings => {foo => {auto_list => [qw/xxx yyy zzz/]}}},
            "Provided, but no value, use autofill"
        );
        like(
            parse_options(['-L=xxx']),
            {settings => {foo => {auto_list => ['xxx']}}},
            "Specified a value"
        );
        like(
            parse_options(['-L=xxx,yyy,baz,bat', '--auto-list=fruit,pear']),
            {settings => {foo => {auto_list => ['xxx', 'yyy', 'baz', 'bat', 'fruit','pear']}}},
            "Specified multiple values"
        );
        like(
            parse_options(['--no-auto-list']),
            {settings => {foo => {auto_list => []}}},
            "Cleared values"
        );
        like(
            dies { parse_options(['-L', 'foo']) },
            qr/'foo' is not a valid option\./,
            "Do not slurp value after space"
        );
    };

    subtest stop => sub {
        my $res = parse_options(['-f', '-L', '--', "-m" => 'do_not=parse', "extra"], stops => ['::', '--'], skip_non_opts => 1);
        like(
            $res,
            {'skipped' => [], 'stop' => '--', 'remains' => ['-m', 'do_not=parse', 'extra']},
            "Stopped at '--', got remaining args",
        );
    };

    subtest env => sub {
        option env => (
            type => 'Scalar',
            from_env_vars => [qw/EXAMPLEA EXAMPLEB EXAMPLEC/],
            clear_env_vars => ['EXAMPLEA'],
            set_env_vars => ['EXAMPLEC'],
        );

        local $ENV{EXAMPLEA} = "A";
        local $ENV{EXAMPLEB} = "B";
        local $ENV{EXAMPLEC} = "C";
        like(
            parse_options([]),
            {settings => {foo => {env => 'A'}}, env => {EXAMPLEA => undef, EXAMPLEC => 'A'}},
            "Set by env var"
        );
        ok(!$ENV{EXAMPLEA}, "Clear env EXAMPLEA");
        is($ENV{EXAMPLEC}, 'A', "Set EXAMPLEC");

        like(
            parse_options([]),
            {settings => {foo => {env => 'B'}}, env => {EXAMPLEA => undef, EXAMPLEC => 'B'}},
            "Set by another env var"
        );
        is($ENV{EXAMPLEC}, 'B', "Set EXAMPLEC");
    };

    subtest env_neg => sub {
        option env_neg => (
            type => 'Scalar',
            from_env_vars => [qw/!EXAMPLEA/],
            clear_env_vars => ['EXAMPLEA'],
            set_env_vars => ['!EXAMPLEX'],
        );

        local $ENV{EXAMPLEA} = 1;
        local $ENV{EXAMPLEX};
        like(
            parse_options([]),
            {settings => {foo => {env_neg => F()}}, env => {EXAMPLEA => undef, EXAMPLEX => F()}},
            "Set by env var"
        );
        ok(!$ENV{EXAMPLEA}, "Clear env EXAMPLEA");
        is($ENV{EXAMPLEX}, F(), "Set EXAMPLEX");

        local $ENV{EXAMPLEA} = 0;
        local $ENV{EXAMPLEX};
        like(
            parse_options([]),
            {settings => {foo => {env_neg => T()}}, env => {EXAMPLEA => undef, EXAMPLEX => T()}},
            "Set by env var"
        );
        ok(!$ENV{EXAMPLEA}, "Clear env EXAMPLEA");
        is($ENV{EXAMPLEX}, T(), "Set EXAMPLEX");

    };


    subtest post => sub {
        my @order;

        option_post_process(sub { push @order => 'A' });
        option_post_process(-5 => sub { push @order => 'B' });
        option_post_process(5  => sub { push @order => 'C' });
        option_post_process(5  => sub {
            my ($options, $state) = @_;
            push @order => 'D';
            like(
                $state,
                {
                    cleared  => {},
                    env      => {},
                    remains  => [],
                    settings => {},
                    skipped  => [],
                },
                "State was passed in",
            );
        });
        parse_options([]);
        is(\@order, [qw/B A C D/], "Callbacks ran in order");
    };

    subtest cli_docs => sub {
        local $ENV{TABLE_TERM_SIZE} = 120;
        is(options->docs('cli'), <<"        EOT", "Got expected docs");

This is the category
  --aut,  --aut ARG,  --aut=ARG,  --auto,  --auto ARG,  --auto=ARG,  -a,  -aARG,  -a ARG,  -a=ARG
  --no-aut
    An auto-field

  --aut2,  --aut2 ARG,  --aut2=ARG,  --no-aut2
    NO DESCRIPTION - FIX ME

  --auto-list,  --auto-list ARG,  --auto-list=ARG,  -L,  -LARG,  -L ARG,  -L=ARG,  --no-auto-list
    an auto list

    Note: Can be specified multiple times

  --auto-map,  --auto-map=key=val,  -A,  -Akey=val,  -A=key=val,  --no-auto-map
    An Auto map

    Note: Can be specified multiple times

  --bar,  --no-bar
    bar boolean

  --baz,  --no-baz
    baz boolean

  --cnt,  --cnt=COUNT,  --count,  --count=COUNT,  -c,  -cc,  -ccc..,  -c=COUNT,  --no-cnt
    A counter

    Note: Can be specified multiple times, counter bumps each time it is used.

  --env ARG,  --env=ARG,  --no-env
    NO DESCRIPTION - FIX ME

    Can also be set with the following environment variables: EXAMPLEA, EXAMPLEB, EXAMPLEC

    The following environment variables will be cleared after arguments are processed: EXAMPLEA

    The following environment variables will be set after arguments are processed: EXAMPLEC

  --foo,  -f,  --no-foo
    foo boolean

  --list ARG,  --list=ARG,  -lARG,  -l ARG,  -l=ARG,  --no-list
    a list

    Note: Can be specified multiple times

  --map key=val,  --map=key=val,  -m key=val,  -mkey=value,  -m=key=val,  --no-map
    A map

    Note: Can be specified multiple times

  --scl ARG,  --scl=ARG,  --scalar ARG,  --scalar=ARG,  -sARG,  -s ARG,  -s=ARG,  --no-scl
    A scalar

  --scl2 ARG,  --scl2=ARG,  --no-scl2
    Another scalar
        EOT
    };


    subtest cli_docs => sub {
        local $ENV{TABLE_TERM_SIZE} = 120;
        is(options->docs('pod', groups => {':{' => '}:'}, category => 'foo', head => 3), <<"        EOT", "Got expected docs");
=head3 This is the category

=over 4

=item --aut

=item --aut ARG

=item --aut=ARG

=item --auto

=item --auto ARG

=item --auto=ARG

=item -a

=item -aARG

=item -a ARG

=item -a=ARG

=item --no-aut

An auto-field


=item --aut2

=item --aut2 ARG

=item --aut2=ARG

=item --no-aut2

NO DESCRIPTION - FIX ME


=item --auto-list

=item --auto-list ARG

=item --auto-list=ARG

=item -L

=item -LARG

=item -L ARG

=item -L=ARG

=item --no-auto-list

an auto list

Can be specified multiple times


=item --auto-map

=item --auto-map=key=val

=item -A

=item -Akey=val

=item -A=key=val

=item --no-auto-map

An Auto map

Can be specified multiple times


=item --bar

=item --no-bar

bar boolean


=item --baz

=item --no-baz

baz boolean


=item --cnt

=item --cnt=COUNT

=item --count

=item --count=COUNT

=item -c

=item -cc

=item -ccc..

=item -c=COUNT

=item --no-cnt

A counter

Can be specified multiple times, counter bumps each time it is used.


=item --env ARG

=item --env=ARG

=item --no-env

NO DESCRIPTION - FIX ME

Can also be set with the following environment variables: C<EXAMPLEA>, C<EXAMPLEB>, C<EXAMPLEC>

The following environment variables will be cleared after arguments are processed: C<EXAMPLEA>

The following environment variables will be set after arguments are processed: C<EXAMPLEC>


=item --foo

=item -f

=item --no-foo

foo boolean


=item --list ARG

=item --list=ARG

=item -lARG

=item -l ARG

=item -l=ARG

=item --no-list

a list

Can be specified multiple times


=item --map key=val

=item --map=key=val

=item -m key=val

=item -mkey=value

=item -m=key=val

=item --no-map

A map

Can be specified multiple times


=item --scl ARG

=item --scl=ARG

=item --scalar ARG

=item --scalar=ARG

=item -sARG

=item -s ARG

=item -s=ARG

=item --no-scl

A scalar


=item --scl2 ARG

=item --scl2=ARG

=item --no-scl2

Another scalar


=back
        EOT
    };

    subtest modules => sub {
        package Foo::Bar;
        main::option_group({no_module => 0} => sub {
            package main;

            option(mod => (type => 'Bool'));

            like(
                parse_options(['--mod']),
                {modules => {'Foo::Bar' => 1}},
                "Option got package name when no_module is not set, and we bumped it when we used the flag from it"
            );

            like(
                parse_options([]),
                {modules => in_set({'Foo::Bar' => FDNE()}, FDNE())},
                "Did not set module as used"
            );
        });
    };
};

done_testing;
