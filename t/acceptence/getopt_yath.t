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
        ok($trigger, "Triggered"); $trigger = 0;
        like(
            parse_options(['--foo']),
            {settings => {foo => {foo => 1}}},
            "Parsed a bool with a default of 1 turned on"
        );
        ok($trigger, "triggered"); $trigger = 0;
        like(
            parse_options(['-f']),
            {settings => {foo => {foo => 1}}},
            "Parsed a bool with a default of 1 turned on"
        );
        ok($trigger, "triggered"); $trigger = 0;
        like(
            dies { parse_options(['-f=0']) },
            qr/Use of 'arg=val' form is not allowed in option '-f=0'\. Arguments are not allowed for this option type\./,
            "Boolean types do not allow an argument"
        );
        ok($trigger, "triggered"); $trigger = 0;
        like(
            parse_options(['--no-foo']),
            {settings => {foo => {foo => 0}}},
            "Parsed a bool with a default of 1 turned off"
        );
        ok($trigger, "triggered"); $trigger = 0;

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

        # Note this was done by printing the value and spot-checking it, so it
        # is a test that the doc output does not accidentally change, there
        # could be bugs that need to be fixed that mean this needs to change.
        is(options->docs('cli'), <<"        EOT", "Got expected docs");

This is the category  (foo)
  [aut]
  -a
  -aARG
  -a=ARG
  --aut
  --auto
  --aut=ARG
  --auto=ARG
  --no-aut
    An auto-field

    default: yyy

    autofill: xxx

  [aut2]
  --aut2
  --aut2=ARG
  --no-aut2
    NO DESCRIPTION - FIX ME

    autofill: zzz

  [auto-list]
  -L
  -L=ARG
  -L='["json","list"]'
  --auto-list
  --auto-list=ARG
  --auto-list='["json","list"]'
  --no-auto-list
    an auto list

    Note: Can be specified multiple times

  [auto-map]
  -A
  -Akey=val
  -A=key=val
  --auto-map
  --auto-map=key=val
  --no-auto-map
    An Auto map

    Note: Can be specified multiple times

  [bar]
  --bar
  --no-bar
    bar boolean

    default: 0

  [baz]
  --baz
  --no-baz
    baz boolean

  [cnt]
  -c
  -cc
  -ccc..
  -c=COUNT
  --cnt
  --count
  --cnt=COUNT
  --count=COUNT
  --no-cnt
    A counter

    Note: Can be specified multiple times, counter bumps each time it is used.

  [env]
  --env ARG
  --env=ARG
  --no-env
    NO DESCRIPTION - FIX ME

    Can also be set with the following environment variables: EXAMPLEA, EXAMPLEB, EXAMPLEC

    The following environment variables will be cleared after arguments are processed: EXAMPLEA

    The following environment variables will be set after arguments are processed: EXAMPLEC

  [env-neg]
  --env-neg ARG
  --env-neg=ARG
  --no-env-neg
    NO DESCRIPTION - FIX ME

    Can also be set with the following environment variables: !EXAMPLEA

    The following environment variables will be cleared after arguments are processed: EXAMPLEA

    The following environment variables will be set after arguments are processed: !EXAMPLEX

  [foo]
  -f
  --foo
  --no-foo
    foo boolean

    default: 1

  [list]
  -l ARG
  -l=ARG
  -l '["json","list"]'
  -l='["json","list"]'
  --list ARG
  --list=ARG
  --list '["json","list"]'
  --list='["json","list"]'
  --no-list
    a list

    Note: Can be specified multiple times

  [map]
  -m key=val
  -m=key=val
  -mkey=value
  -m '{"json":"hash"}'
  -m='{"json":"hash"}'
  --map key=val
  --map=key=val
  --map '{"json":"hash"}'
  --map='{"json":"hash"}'
  --no-map
    A map

    Note: Can be specified multiple times

  [scl]
  -sARG
  -s ARG
  -s=ARG
  --scl ARG
  --scl=ARG
  --scalar ARG
  --scalar=ARG
  --no-scl
    A scalar

    default: I am a scalar

  [scl2]
  --scl2 ARG
  --scl2=ARG
  --no-scl2
    Another scalar
        EOT
    };


    subtest pod_docs => sub {
        local $ENV{TABLE_TERM_SIZE} = 120;

        # Note this was done by printing the value and spot-checking it, so it
        # is a test that the doc output does not accidentally change, there
        # could be bugs that need to be fixed that mean this needs to change.
        is(options->docs('pod', groups => {':{' => '}:'}, head => 3), <<"        EOT", "Got expected docs");
=head3 This is the category

=over 4

=item -a

=item -aARG

=item -a=ARG

=item --aut

=item --auto

=item --aut=ARG

=item --auto=ARG

=item --no-aut

An auto-field


=item --aut2

=item --aut2=ARG

=item --no-aut2

NO DESCRIPTION - FIX ME


=item -L

=item -L=ARG

=item -L='["json","list"]'

=item -L=:{ ARG1 ARG2 ... }:

=item --auto-list

=item --auto-list=ARG

=item --auto-list='["json","list"]'

=item --auto-list=:{ ARG1 ARG2 ... }:

=item --no-auto-list

an auto list

Note: Can be specified multiple times


=item -A

=item -Akey=val

=item -A=key=val

=item --auto-map

=item --auto-map=key=val

=item --no-auto-map

An Auto map

Note: Can be specified multiple times


=item --bar

=item --no-bar

bar boolean


=item --baz

=item --no-baz

baz boolean


=item -c

=item -cc

=item -ccc..

=item -c=COUNT

=item --cnt

=item --count

=item --cnt=COUNT

=item --count=COUNT

=item --no-cnt

A counter

Note: Can be specified multiple times, counter bumps each time it is used.


=item --env ARG

=item --env=ARG

=item --no-env

NO DESCRIPTION - FIX ME

Can also be set with the following environment variables: C<EXAMPLEA>, C<EXAMPLEB>, C<EXAMPLEC>

The following environment variables will be cleared after arguments are processed: C<EXAMPLEA>

The following environment variables will be set after arguments are processed: C<EXAMPLEC>


=item --env-neg ARG

=item --env-neg=ARG

=item --no-env-neg

NO DESCRIPTION - FIX ME

Can also be set with the following environment variables: C<!EXAMPLEA>

The following environment variables will be cleared after arguments are processed: C<EXAMPLEA>

The following environment variables will be set after arguments are processed: C<!EXAMPLEX>


=item -f

=item --foo

=item --no-foo

foo boolean


=item -l ARG

=item -l=ARG

=item -l '["json","list"]'

=item -l='["json","list"]'

=item -l :{ ARG1 ARG2 ... }:

=item -l=:{ ARG1 ARG2 ... }:

=item --list ARG

=item --list=ARG

=item --list '["json","list"]'

=item --list='["json","list"]'

=item --list :{ ARG1 ARG2 ... }:

=item --list=:{ ARG1 ARG2 ... }:

=item --no-list

a list

Note: Can be specified multiple times


=item -m key=val

=item -m=key=val

=item -mkey=value

=item -m '{"json":"hash"}'

=item -m='{"json":"hash"}'

=item -m:{ KEY1 VAL KEY2 :{ VAL1 VAL2 ... }: ... }:

=item -m :{ KEY1 VAL KEY2 :{ VAL1 VAL2 ... }: ... }:

=item -m=:{ KEY1 VAL KEY2 :{ VAL1 VAL2 ... }: ... }:

=item --map key=val

=item --map=key=val

=item --map '{"json":"hash"}'

=item --map='{"json":"hash"}'

=item --map :{ KEY1 VAL KEY2 :{ VAL1 VAL2 ... }: ... }:

=item --map=:{ KEY1 VAL KEY2 :{ VAL1 VAL2 ... }: ... }:

=item --no-map

A map

Note: Can be specified multiple times


=item -sARG

=item -s ARG

=item -s=ARG

=item --scl ARG

=item --scl=ARG

=item --scalar ARG

=item --scalar=ARG

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
