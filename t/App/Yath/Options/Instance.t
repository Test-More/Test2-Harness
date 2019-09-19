use Test2::V0 -target => 'App::Yath::Options::Instance';
use Test2::Plugin::DieOnFail;

{
    no warnings 'once';
    @App::Yath::Command::empty::ISA = ('App::Yath::Command');
    *App::Yath::Command::empty::options = sub { $CLASS->new };
}

subtest init => sub {
    my $one = $CLASS->new();

    isa_ok($one, [$CLASS], "Got an instance");

    is(
        $one,
        {
            lookup         => {},
            cmd_list             => [],
            pre_list => [],
            all => [],
            settings => {},
        },
        "Set defaults",
    );
};

subtest reset_processing => sub {
    @App::Yath::Command::empty::ISA = ('App::Yath::Command');
    *App::Yath::Command::empty::options = sub { $CLASS->new };

    my $one = $CLASS->new(
        pending_pre  => [qw/a b c/],
        pending_cmd  => [qw/a b c/],
        pending_post => [qw/a b c/],
    );

    $one->settings->{foo} = 1;
    $one->set_args(['foo']);
    $one->set_command_class('App::Yath::Command::empty');

    is(
        $one,
        {
            lookup   => {},
            cmd_list => [],
            pre_list => [],
            all      => [],

            settings      => {foo => 1},
            pending_pre   => [qw/a b c/],
            pending_cmd   => [qw/a b c/],
            pending_post  => [qw/a b c/],
            command_class => 'App::Yath::Command::empty',
            args          => ['foo'],
        },
        "attributes are as expected before reset"
    );

    my $clone = { %$one };

    $one->reset_processing();
    is(
        $one,
        {
            # NO CHANGE!
            lookup           => exact_ref($clone->{lookup}),
            cmd_list             => exact_ref($clone->{cmd_list}),
            pre_list => exact_ref($clone->{pre_list}),
            all             => exact_ref($clone->{all}),

            # RESET TO A NEW EMPTY HASH
            settings             => {},

            # DELETED
            pending_pre  => DNE(),
            pending_cmd  => DNE(),
            pending_post => DNE(),
            _command_class       => DNE(),
            _args                => DNE(),
        },
        "Reset expected attribures, left others alone"
    );

};

subtest parse_option_caller => sub {
    no warnings 'once';
    my $one = $CLASS->new();

    require App::Yath::Command;
    local @App::Yath::Command::XXX::ISA = ('App::Yath::Command');
    is(
        {$one->_parse_option_caller('App::Yath::Command::XXX')},
        {from_command => 'XXX'},
        "Got data from command package"
    );

    local *App::Yath::Command::XXX::option_prefix = sub { 'foo' };
    is(
        {$one->_parse_option_caller('App::Yath::Command::XXX')},
        {from_command => 'XXX', prefix => 'foo'},
        "Got data from command package, and got prefix from class"
    );

    is(
        {$one->_parse_option_caller('App::Yath::Plugin::Foo')},
        {from_plugin => 'App::Yath::Plugin::Foo', prefix => 'foo'},
        "Got data from plugin package"
    );
};

subtest parse_option_args => sub {
    my $one = $CLASS->new();

    is(
        {$one->_parse_option_args('foo')},
        {field => 'foo', type => undef},
        "Super simple args, just a field name"
    );

    is(
        {$one->_parse_option_args('foo=b')},
        {field => 'foo', type => 'b'},
        "field and type in a single string"
    );

    is(
        {$one->_parse_option_args('foo=s')},
        {field => 'foo', type => 's'},
        "field and complex type in a single string"
    );

    is(
        {$one->_parse_option_args('foo' => 'b')},
        {field => 'foo', type => 'b'},
        "field and type in 2 args"
    );

    is(
        {$one->_parse_option_args('foo', 's')},
        {field => 'foo', type => 's'},
        "field and complex type in a 2 args"
    );

    is(
        {$one->_parse_option_args('foo', type => 's')},
        {field => 'foo', type => 's'},
        "field and complex type in a 3 args"
    );

    is(
        [$one->_parse_option_args('foo', type => 's', pass => 'through', another => 'one', another => 'two')],
        [type => 's', pass => 'through', another => 'one', another => 'two', field => 'foo'],
        "Arg passthrough, including a duplicate key"
    );
};

subtest index_option => sub {
    my ($one, $opt);

    $one = $CLASS->new();
    my $opt1 = App::Yath::Option->new(field => 'foo', from_command => 'bar', short => 'f', alt => [qw/x y/], trace => ['foo', 'file.pm', '42']);
    $one->_index_option($opt1);
    is(
        $one,
        {
            lookup => {
                foo => exact_ref($opt1),
                f   => exact_ref($opt1),
                x   => exact_ref($opt1),
                y   => exact_ref($opt1),
            },

            all      => [],
            cmd_list => [],
            pre_list => [],
            settings => {},
        },
        "Indexed the command option"
    );

    like(
        dies { $one->_index_option($opt1) },
        qr/Option 'foo' was already defined \(file\.pm line 42\)/,
        "Cannot replace existing options (primary)"
    );

    $opt = App::Yath::Option->new(field => 'xxx', from_command => 'bar', short => 'f', alt => [qw/x y/], trace => ['foo', 'file.pm', '42']);
    like(
        dies { $one->_index_option($opt) },
        qr/Option 'x' was already defined \(file\.pm line 42\)/,
        "Cannot replace existing options (from alt)"
    );

    $opt = App::Yath::Option->new(field => 'yyy', from_command => 'bar', short => 'f', trace => ['foo', 'file.pm', '42']);
    like(
        dies { $one->_index_option($opt) },
        qr/Option 'f' was already defined \(file\.pm line 42\)/,
        "Cannot replace existing options (from short)"
    );
};

subtest _list_option => sub {
    my ($one, $opt);

    $one = $CLASS->new();
    $opt = App::Yath::Option->new(field => 'foo', pre_command => 1);
    $one->_list_option($opt);
    is(
        $one,
        {
            pre_list => [exact_ref($opt)],
            all      => [],
            lookup   => {},
            cmd_list => [],
            settings => {},
        },
        "Listed properly in pre-command"
    );

    $one = $CLASS->new();
    $opt = App::Yath::Option->new(field => 'foo', from_command => 'xxx');
    $one->_list_option($opt);
    is(
        $one,
        {
            cmd_list => [exact_ref($opt)],
            all      => [],
            pre_list => [],
            lookup   => {},
            settings => {},
        },
        "Listed properly in command"
    );

    $one = $CLASS->new();
    $opt = App::Yath::Option->new(field => 'foo');
    $one->_list_option($opt);
    is(
        $one,
        {
            cmd_list => [exact_ref($opt)],
            all      => [],
            pre_list => [],
            lookup   => {},
            settings => {},
        },
        "Listed properly as an option for all commands"
    );
};


subtest option => sub {
    my $one = $CLASS->new();

    my $opt = do { package App::Yath; $one->option('foo') };

    is(
        $opt,
        {
            trace => ['App::Yath', __FILE__, T()],

            field => 'foo',
            name  => 'foo',
            type  => 'b',

            description => 'NO DESCRIPTION - FIX ME',
            category    => 'NO CATEGORY - FIX ME',
        },
        "Option is as desired",
    );

    is(
        $one,
        {
            lookup   => {foo => exact_ref($opt)},
            cmd_list => [exact_ref($opt)],
            all      => [exact_ref($opt)],
            pre_list => [],
            settings => {},
        },
        "Added to lookup and list",
    );
};



subtest parse_long_option => sub {
    my $one = $CLASS->new();

    like(
        dies { $one->_parse_long_option('xyz') },
        qr/Invalid long option: xyz/,
        "Long options must start with --"
    );

    like(
        dies { $one->_parse_long_option('-xyz') },
        qr/Invalid long option: -xyz/,
        "Long options must start with --, not just a single dash"
    );

    is(
        [$one->_parse_long_option('--foo')],
        ['foo', 'foo', undef],
        "Parsed long option --foo"
    );

    is(
        [$one->_parse_long_option('--foo-bar')],
        ['foo-bar', 'foo-bar', undef],
        "Parsed long option --foo-bar"
    );

    is(
        [$one->_parse_long_option('--no-foo')],
        ['foo', 'no-foo', undef],
        "Parsed long option --no-foo"
    );

    is(
        [$one->_parse_long_option('--foo=bar')],
        ['foo', 'foo', 'bar'],
        "Parsed long option --foo=bar"
    );

    is(
        [$one->_parse_long_option('--foo=')],
        ['foo', 'foo', ''],
        "Parsed long option --foo="
    );

    is(
        [$one->_parse_long_option('--foo=bar=baz')],
        ['foo', 'foo', 'bar=baz'],
        "Parsed long option --foo=bar=baz"
    );

    is(
        [$one->_parse_long_option('--no-foo=bar')],
        ['foo', 'no-foo', 'bar'],
        "Parsed long option --no-foo=bar"
    );
};

subtest parse_short_option => sub {
    my $one = $CLASS->new();

    like(
        dies { $one->_parse_short_option('x') },
        qr/Invalid short option: x/,
        "short options must start with -"
    );

    like(
        dies { $one->_parse_short_option('--x') },
        qr/Invalid short option: --x/,
        "short options must start with -, not --"
    );

    is(
        [$one->_parse_short_option('-x')],
        ['x', undef, F()],
        "Parsed short option 'x' from -x"
    );

    is(
        [$one->_parse_short_option('-xyz')],
        ['x', 'yz', F()],
        "Parsed short option 'x' from -xyz"
    );

    is(
        [$one->_parse_short_option('-x=yz')],
        ['x', 'yz', T()],
        "Parsed short option {'x' => 'yz'} from -x=yz"
    );

    is(
        [$one->_parse_short_option('-x=y=z')],
        ['x', 'y=z', T()],
        "Parsed short option {'x' => 'y=z'} from -x=y=z"
    );
};

subtest handle_long_option => sub {
    my $one = $CLASS->new();
    my $settings = {};
    my $args = [];

    my $lookup = {
        long => {
            'foo'     => App::Yath::Option->new(field => 'foo',     type => 's'),
            'bar-baz' => App::Yath::Option->new(field => 'bar-baz', type => 'm'),
            'xxx'     => App::Yath::Option->new(field => 'xxx',     type => 'b'),
            'no-xxx'  => App::Yath::Option->new(field => 'no-xxx',  type => 'b'),
            'ccc'     => App::Yath::Option->new(field => 'ccc',     type => 'c'),
            'ddd'     => App::Yath::Option->new(field => 'ddd',     type => 'd'),
            'DDD'     => App::Yath::Option->new(field => 'DDD',     type => 'D'),
        },
    };

    is(
        $one->_handle_long_option('--xyz', $lookup, $args, $settings),
        undef,
        "No opt for the arg"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--foo', $lookup, $args),
        [exact_ref($lookup->{long}->{foo}), 'handle', 'myval'],
        "Found scalar opt, got value from args"
    );
    is($args, ['extra'], "shifted value from array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--foo=xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{foo}), 'handle', 'xxx'],
        "Found scalar opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--no-foo', $lookup, $args),
        [exact_ref($lookup->{long}->{foo}), 'handle_negation'],
        "Negated scalar"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--no-foo=xxx', $lookup, $args) },
        "Option --no-foo does not take an argument\n",
        "Cannot set a value on negation"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--bar-baz', $lookup, $args),
        [exact_ref($lookup->{long}->{'bar-baz'}), 'handle', 'myval'],
        "found multi opt, got value from array",
    );
    is($args, ['extra'], "shifted value from array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--bar-baz=xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{'bar-baz'}), 'handle', 'xxx'],
        "Found multi opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--no-bar-baz', $lookup, $args),
        [exact_ref($lookup->{long}->{'bar-baz'}), 'handle_negation'],
        "Negated scalar"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--no-bar-baz=xxx', $lookup, $args) },
        "Option --no-bar-baz does not take an argument\n",
        "Cannot set a value on negation"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{'xxx'}), 'handle', T()],
        "found boolean, value is true",
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--xxx=foo', $lookup, $args) },
        "Option --xxx does not take an argument\n",
        "Cannot set a value on negation"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--no-xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{'no-xxx'}), 'handle', T()],
        "found no- prefixe'd option, so not a regular negation",
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--ccc', $lookup, $args),
        [exact_ref($lookup->{long}->{'ccc'}), 'handle', 1],
        "found counter, value is 1",
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--ccc=xxx', $lookup, $args) },
        "Option --ccc does not take an argument\n",
        "Counter type does not take a value"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--ddd', $lookup, $args),
        [exact_ref($lookup->{long}->{ddd}), 'handle', 1],
        "Found 'default' opt, value is 1 without assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--ddd=xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{ddd}), 'handle', 'xxx'],
        "Found 'default' opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--no-ddd', $lookup, $args),
        [exact_ref($lookup->{long}->{ddd}), 'handle_negation'],
        "Negated default"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--no-ddd=xxx', $lookup, $args) },
        "Option --no-ddd does not take an argument\n",
        "Cannot set a value on negation"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--DDD', $lookup, $args),
        [exact_ref($lookup->{long}->{DDD}), 'handle', 1],
        "Found 'Default' opt, value is 1 without assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--DDD=xxx', $lookup, $args),
        [exact_ref($lookup->{long}->{DDD}), 'handle', 'xxx'],
        "Found 'Default' opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_long_option('--no-DDD', $lookup, $args),
        [exact_ref($lookup->{long}->{DDD}), 'handle_negation'],
        "Negated default"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_long_option('--no-DDD=xxx', $lookup, $args) },
        "Option --no-DDD does not take an argument\n",
        "Cannot set a value on negation"
    );
};

subtest handle_short_option => sub {
    my $one = $CLASS->new();
    my $settings = {};
    my $args = [];

    my $lookup = {
        short => {
            'f' => App::Yath::Option->new(field => 'foo',     short => 'f', type => 's'),
            'b' => App::Yath::Option->new(field => 'bar-baz', short => 'b', type => 'm'),
            'x' => App::Yath::Option->new(field => 'xxx',     short => 'x', type => 'b'),
            'c' => App::Yath::Option->new(field => 'ccc',     short => 'c', type => 'c'),
            'd' => App::Yath::Option->new(field => 'ddd',     short => 'd', type => 'd'),
            'D' => App::Yath::Option->new(field => 'DDD',     short => 'D', type => 'D'),
        },
    };

    is(
        $one->_handle_short_option('-z', $lookup, $args, $settings),
        undef,
        "No opt for the arg"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-f', $lookup, $args),
        [exact_ref($lookup->{short}->{f}), 'handle', 'myval'],
        "Found scalar opt, got value from args"
    );
    is($args, ['extra'], "shifted value from array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-f=xxx', $lookup, $args),
        [exact_ref($lookup->{short}->{f}), 'handle', 'xxx'],
        "Found scalar opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-b', $lookup, $args),
        [exact_ref($lookup->{short}->{'b'}), 'handle', 'myval'],
        "found multi opt, got value from array",
    );
    is($args, ['extra'], "shifted value from array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-b=xxx', $lookup, $args),
        [exact_ref($lookup->{short}->{'b'}), 'handle', 'xxx'],
        "Found multi opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-x', $lookup, $args),
        [exact_ref($lookup->{short}->{'x'}), 'handle', T()],
        "found boolean, value is true",
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-xyz', $lookup, $args),
        [exact_ref($lookup->{short}->{'x'}), 'handle', T()],
        "found boolean, value is true",
    );
    is($args, ['-yz', 'myval', 'extra'], "Put remaining short options back into array");

    is(
        dies { $one->_handle_short_option('-x=foo', $lookup, $args) },
        "Option -x does not take an argument\n",
        "Cannot set a value on negation"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-c', $lookup, $args),
        [exact_ref($lookup->{short}->{'c'}), 'handle', 1],
        "found counter, value is 1",
    );
    is($args, ['myval', 'extra'], "did not modify array");

    is(
        dies { $one->_handle_short_option('-c=xxx', $lookup, $args) },
        "Option -c does not take an argument\n",
        "Counter type does not take a value"
    );

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-d', $lookup, $args),
        [exact_ref($lookup->{short}->{d}), 'handle', 1],
        "Found 'default' opt, value is 1 without assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-d=xxx', $lookup, $args),
        [exact_ref($lookup->{short}->{d}), 'handle', 'xxx'],
        "Found 'default' opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-dxxx', $lookup, $args),
        [exact_ref($lookup->{short}->{d}), 'handle', 'xxx'],
        "Found 'default' opt, got value from coupling"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-D', $lookup, $args),
        [exact_ref($lookup->{short}->{D}), 'handle', 1],
        "Found 'Default' opt, value is 1 without assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-D=xxx', $lookup, $args),
        [exact_ref($lookup->{short}->{D}), 'handle', 'xxx'],
        "Found 'Default' opt, got value from assignment"
    );
    is($args, ['myval', 'extra'], "did not modify array");

    $args = ['myval', 'extra'];
    is(
        $one->_handle_short_option('-Dxxx', $lookup, $args),
        [exact_ref($lookup->{short}->{D}), 'handle', 'xxx'],
        "Found 'Default' opt, got value from coupling"
    );
    is($args, ['myval', 'extra'], "did not modify array");
};

subtest _grab_opts => sub {
    my $one = $CLASS->new();

    my $opts = [
        App::Yath::Option->new(field => 'foo',     short => 'f', type => 's'),
        App::Yath::Option->new(field => 'bar-baz', short => 'b', type => 'm'),
        App::Yath::Option->new(field => 'xxx',     short => 'x', type => 'b'),
        App::Yath::Option->new(field => 'ccc',     short => 'c', type => 'c'),
        App::Yath::Option->new(field => 'ddd',     short => 'd', type => 'd'),
        App::Yath::Option->new(field => 'DDD',     short => 'D', type => 'D'),
    ];

    my $args = ['--foo' => 'fv', '-b=a', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    is(
        [$one->_grab_opts($opts, 'foo')],
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],

            [exact_ref($opts->[1]), 'handle', 'a'],

            [exact_ref($opts->[1]), 'handle', 'b'],

            [exact_ref($opts->[2]), 'handle', 1],

            [exact_ref($opts->[3]), 'handle', 1],
            [exact_ref($opts->[3]), 'handle', 1],

            [exact_ref($opts->[4]), 'handle', 1],
            [exact_ref($opts->[5]), 'handle', 1],

            [exact_ref($opts->[5]), 'handle', 'dv'],

            [exact_ref($opts->[2]), 'handle_negation'],
        ],
        "Processed all options"
    );
    is($args, ['nonopt', 'another_non_opt'], "Kept non-options in args array");

    $args = ['--foo' => 'fv', '-b=a', '--', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    is(
        [$one->_grab_opts($opts, 'foo')],
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '--'"
    );
    is($args, ['-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after '--'");

    $args = ['--foo' => 'fv', '-b=a', '::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    is(
        [$one->_grab_opts($opts, 'foo')],
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '::'"
    );
    is($args, ['::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after and including '::'");


    $args = ['--foo' => 'fv', '-b=a', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    is(
        [$one->_grab_opts($opts, 'foo', stop_at_non_opt => 1)],
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
            [exact_ref($opts->[1]), 'handle', 'b'],
        ],
        "Stopped at first non-opt argument"
    );
    is($args, ['nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after and including the first non-opt");

    $one->reset_processing();
    $one->set_args(['-z']);
    is(
        dies { $one->_grab_opts($opts, 'foo') },
        "Invalid foo option: -z\n",
        "Die for invalid option"
    );
};

subtest grab_pre_command_opts => sub {
    my $one = $CLASS->new();

    my $opts = [
        App::Yath::Option->new(field => 'foo',     short => 'f', type => 's'),
        App::Yath::Option->new(field => 'bar-baz', short => 'b', type => 'm'),
        App::Yath::Option->new(field => 'xxx',     short => 'x', type => 'b'),
        App::Yath::Option->new(field => 'ccc',     short => 'c', type => 'c'),
        App::Yath::Option->new(field => 'ddd',     short => 'd', type => 'd'),
        App::Yath::Option->new(field => 'DDD',     short => 'D', type => 'D'),
    ];

    my $control = mock $CLASS => (
        override => [ _pre_command_options => sub { $opts } ],
    );

    my $args = ['--foo' => 'fv', '-b=a', '-b' => 'b', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->grab_pre_command_opts();
    is(
        $one->pending_pre,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],

            [exact_ref($opts->[1]), 'handle', 'a'],

            [exact_ref($opts->[1]), 'handle', 'b'],

            [exact_ref($opts->[2]), 'handle', 1],

            [exact_ref($opts->[3]), 'handle', 1],
            [exact_ref($opts->[3]), 'handle', 1],

            [exact_ref($opts->[4]), 'handle', 1],
            [exact_ref($opts->[5]), 'handle', 1],

            [exact_ref($opts->[5]), 'handle', 'dv'],

            [exact_ref($opts->[2]), 'handle_negation'],
        ],
        "Processed all options"
    );
    is($args, ['non_opt'], "Kept non-options in args array");

    $args = ['--foo' => 'fv', '-b=a', '--', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->grab_pre_command_opts();
    is(
        $one->pending_pre,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '--'"
    );
    is($args, ['-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after '--'");

    $args = ['--foo' => 'fv', '-b=a', '::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->grab_pre_command_opts();
    is(
        $one->pending_pre,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '::'"
    );
    is($args, ['::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after and including '::'");


    $args = ['--foo' => 'fv', '-b=a', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->grab_pre_command_opts();
    is(
        $one->pending_pre,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
            [exact_ref($opts->[1]), 'handle', 'b'],
        ],
        "Stopped at first non-opt argument"
    );
    is($args, ['nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after and including the first non-opt");

    $args = ['--foo' => 'fv', '-z', 'blah'];
    $one->reset_processing();
    $one->set_args($args);
    $one->grab_pre_command_opts();
    is(
        $one->pending_pre,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
        ],
        "Stopped at unknown option (assume it is a command option)"
    );
    is($args, ['-z', 'blah'], "Kept everything after and including the first invalid option");
};

subtest args => sub {
    my $one = $CLASS->new();

    $one->set_args(['a']);
    is($one->args, ['a'], "Set args");

    like(
        dies { $one->set_args(['foo']) },
        qr/'args' has already been set/,
        "Cannot change args without a full reset"
    );
};

subtest process_opts => sub {
    my $one = $CLASS->new(settings => {baz => 123});

    my $foo = App::Yath::Option->new(field => 'foo', type => 's', post_process => sub { 'foo' });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's', post_process => sub { 'bar' });
    my $baz = App::Yath::Option->new(field => 'baz', type => 's');

    $one->_process_opts(
        [
            [$foo, 'handle', 'FoO'],
            [$bar, 'handle', 'BaR'],
            [$baz, 'handle_negation'],
        ]
    );

    is(
        $one->settings,
        {baz => undef, foo => 'FoO', bar => 'BaR'},
        "Settings modified"
    );

    is(
        $one->pending_post,
        [
            [exact_ref($foo), exact_ref($foo->post_process)],
            [exact_ref($bar), exact_ref($bar->post_process)],
        ],
        "Got post-actions"
    );
};

subtest process_pre_command_opts => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', post_process => sub { 'foo' });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's', post_process => sub { 'bar' });
    my $baz = App::Yath::Option->new(field => 'baz', type => 's');

    my $one = $CLASS->new(
        settings            => {baz => 123},
        pending_pre => [
            [$foo, 'handle', 'FoO'],
            [$bar, 'handle', 'BaR'],
            [$baz, 'handle_negation'],
        ],
    );

    $one->process_pre_command_opts();
    ok(!$one->pending_pre, "Cleared pending options");

    is(
        $one->settings,
        {baz => undef, foo => 'FoO', bar => 'BaR'},
        "Settings modified"
    );

    is(
        $one->pending_post,
        [
            [exact_ref($foo), exact_ref($foo->post_process)],
            [exact_ref($bar), exact_ref($bar->post_process)],
        ],
        "Got post-actions"
    );
};

subtest process_command_opts => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', post_process => sub { 'foo' });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's', post_process => sub { 'bar' });
    my $baz = App::Yath::Option->new(field => 'baz', type => 's');

    my $one = $CLASS->new(
        settings            => {baz => 123},
        pending_cmd => [
            [$foo, 'handle', 'FoO'],
            [$bar, 'handle', 'BaR'],
            [$baz, 'handle_negation'],
        ],
    );

    $one->process_command_opts();
    ok(!$one->pending_cmd, "Cleared pending options");

    is(
        $one->settings,
        {baz => undef, foo => 'FoO', bar => 'BaR'},
        "Settings modified"
    );

    is(
        $one->pending_post,
        [
            [exact_ref($foo), exact_ref($foo->post_process)],
            [exact_ref($bar), exact_ref($bar->post_process)],
        ],
        "Got post-actions"
    );
};

subtest process_option_post_actions => sub {
    my $one = $CLASS->new();

    like(
        dies { $one->process_option_post_actions() },
        qr/The 'args' attribute has not yet been set/,
        "Need args first"
    );

    $one->set_args(['foo']);

    like(
        dies { $one->process_option_post_actions('x') },
        qr/The 'command_class' attribute has not yet been set/,
        "Need command class first"
    );

    $one->set_command_class('App::Yath::Command::xxx');

    like(
        dies { $one->process_option_post_actions('x') },
        qr/The process_option_post_actions requires an App::Yath::Command instance, got: x/,
        "Need to pass in a command"
    );

    like(
        dies { $one->process_option_post_actions({}) },
        qr/The process_option_post_actions requires an App::Yath::Command instance, got: HASH/,
        "Need to pass in a blessed command"
    );

    like(
        dies { $one->process_option_post_actions(bless {}, 'xxx') },
        qr/The process_option_post_actions requires an App::Yath::Command instance, got: xxx/,
        "Need to pass in a valid command"
    );

    like(
        dies { $one->process_option_post_actions(bless {}, 'App::Yath::Command::yyy') },
        qr/The process_option_post_actions requires an App::Yath::Command instance, got: App::Yath::Command::yyy/,
        "Command must match command class"
    );

    delete $one->{pending_post};
    ok(
        lives { $one->process_option_post_actions(bless {}, 'App::Yath::Command::xxx') },
        "Nothing to do is not an exception"
    );

    my $counter = 1;
    my %post;
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', post_process => sub { $post{foo} = [ $counter++, @_] });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's', post_process => sub { $post{bar} = [ $counter++, @_] });
    my $baz = App::Yath::Option->new(field => 'baz', type => 's', post_process => sub { $post{baz} = [ $counter++, @_] });

    $one->{pending_post} = [
        [$foo, $foo->post_process],
        [$bar, $bar->post_process],
        [$baz, $baz->post_process],
    ];

    my $cmd = bless {}, 'App::Yath::Command::xxx';
    $one->process_option_post_actions($cmd);
    is(
        \%post,
        {
            foo => [ 3, opt => exact_ref($foo), args => exact_ref($one->args), settings => exact_ref($one->settings), command => exact_ref($cmd)],
            bar => [ 2, opt => exact_ref($bar), args => exact_ref($one->args), settings => exact_ref($one->settings), command => exact_ref($cmd)],
            baz => [ 1, opt => exact_ref($baz), args => exact_ref($one->args), settings => exact_ref($one->settings), command => exact_ref($cmd)],
        },
        "Post actions completed correctly"
    );
    ok(!$one->pending_post, "Cleared post actions");

    $one->{pending_post} = [
        [$foo, $foo->post_process],
        [$bar, $bar->post_process],
        [$baz, $baz->post_process],
    ];
    $one->process_option_post_actions();
    is(
        \%post,
        {
            foo => [ 6, opt => exact_ref($foo), args => exact_ref($one->args), settings => exact_ref($one->settings)],
            bar => [ 5, opt => exact_ref($bar), args => exact_ref($one->args), settings => exact_ref($one->settings)],
            baz => [ 4, opt => exact_ref($baz), args => exact_ref($one->args), settings => exact_ref($one->settings)],
        },
        "Post actions completed correctly with no command"
    );
    ok(!$one->pending_post, "Cleared post actions");
};

subtest populate_pre_defaults => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', default => sub { 'FoO' });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's');
    my $baz = App::Yath::Option->new(field => 'baz', type => 's', default => sub { 'bAz' });
    my $bat = App::Yath::Option->new(field => 'bat', type => 's', default => sub { 'bAt' });

    my $one = $CLASS->new(
        settings => {baz => 123},

        pre_list => [$foo, $bar, $baz, $bat],
    );

    $one->populate_pre_defaults();

    is(
        $one->settings,
        {
            foo => 'FoO',
            baz => 123,
            bat => 'bAt',
        },
        "Populated defaults where there were defaults, but did not modify already populated fields"
    );
};

subtest populate_cmd_defaults => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', default => sub { 'FoO' });
    my $bar = App::Yath::Option->new(field => 'bar', type => 's');
    my $baz = App::Yath::Option->new(field => 'baz', type => 's', default => sub { 'bAz' });
    my $bat = App::Yath::Option->new(field => 'bat', type => 's', default => sub { 'bAt' });

    my $one = $CLASS->new(settings => {baz => 123});

    $one->set_command_class('App::Yath::Command');
    my $control = mock $CLASS => (
        override => [
            _command_options => sub { [$foo, $bar, $baz, $bat] },
        ],
    );

    $one->populate_cmd_defaults();

    is(
        $one->settings,
        {
            foo => 'FoO',
            baz => 123,
            bat => 'bAt',
        },
        "Populated defaults where there were defaults, but did not modify already populated fields"
    );
};

subtest include_option => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', trace => [__PACKAGE__, __FILE__, __LINE__]);
    my $one = $CLASS->new();

    $one->include_option($foo);

    is(
        $one,
        {
            lookup           => {'foo' => exact_ref($foo)},
            cmd_list             => [exact_ref($foo)],
            all             => [exact_ref($foo)],
            option_category_lists   => {},
            option_command_lists    => {},
            settings                => {},
            pre_list => [],
            option_command_lookup   => {},
        },
        "Added option"
    );
};

subtest include => sub {
    my $foo = App::Yath::Option->new(field => 'foo', type => 's', trace => [__PACKAGE__, __FILE__, __LINE__]);
    my $bar = App::Yath::Option->new(field => 'bar', type => 's', trace => [__PACKAGE__, __FILE__, __LINE__]);

    my $one = $CLASS->new();
    $one->include_option($foo);

    my $two = $CLASS->new();
    $two->include_option($bar);

    $one->include($two);

    is(
        $one,
        {
            lookup           => {foo => exact_ref($foo), bar => exact_ref($bar)},
            cmd_list             => [exact_ref($foo), exact_ref($bar)],
            all             => [exact_ref($foo), exact_ref($bar)],
            option_category_lists   => {},
            option_command_lists    => {},
            settings                => {},
            pre_list => [],
            option_command_lookup   => {},
        },
        "Merged options"
    );
};

done_testing;

__END__


subtest command_options => sub {
    my $one = $CLASS->new();

    {
        package App::Yath;
        $one->option('x' => type => 's', description => '* - x');
        $one->option('y' => type => 'b',  description => '* - y');

        $one->option('foo', type => 'b', description => '*cat - foo', categories => [qw/foo/]);
        $one->option('bar', type => 'b', description => '*cat - bar', categories => [qw/bar/]);
        $one->option('baz', type => 'b', description => '*cat - baz', categories => [qw/baz/]);
        $one->option('bat', type => 'b', description => '*cat - bat', categories => [qw/bat/]);
        $one->option('bug', type => 'b', description => '*cat - bug', categories => [qw/bug/]);

        package App::Yath::Command::xxx_a;
        use parent 'App::Yath::Command';
        sub option_categories { qw/ foo bar / }
        $one->option('a', type => 'c', description => 'xxx_a - a');
        $one->option('x', type => 'c', description => 'xxx_a - x');

        package App::Yath::Command::xxx_b;
        our @ISA = ('App::Yath::Command::xxx_a');
        sub option_categories { qw/ baz bat / }
        $one->option('b', type => 'c', description => 'xxx_b - b');

        package App::Yath::Command::xxx_c;
        our @ISA = ('App::Yath::Command::xxx_b');
        sub option_categories { qw/ bat / }
        $one->option('c', type => 'c', description => 'xxx_c - c');
        $one->option('x', type => 'b', description => 'xxx_c - x');
    }

    $one->reset_processing;
    $one->set_command_class('App::Yath::Command::xxx_a');
    like(
        $one->_command_options(),
        array {
            # Command specific
            item {description => 'xxx_a - a'};
            item {description => 'xxx_a - x'};

            # Categories
            item {description => '*cat - foo'};
            item {description => '*cat - bar'};

            # Globals
            item {description => '* - x'};    # This conflict gets removed in _build_spec()
            item {description => '* - y'};

            end;
        },
        "Got expected options for command xxx_a"
    );

    $one->reset_processing;
    $one->set_command_class('App::Yath::Command::xxx_b');
    like(
        $one->_command_options(),
        array {
            # Command specific
            item {description => 'xxx_b - b'};

            # Parent command
            item {description => 'xxx_a - a'};
            item {description => 'xxx_a - x'};

            # Command categories
            item {description => '*cat - baz'};
            item {description => '*cat - bat'};

            # Parent categories
            item {description => '*cat - foo'};
            item {description => '*cat - bar'};

            # Globals
            item {description => '* - x'};    # This conflict gets removed in _build_spec()
            item {description => '* - y'};

            end;
        },
        "Got expected options for command xxx_b"
    );

    $one->reset_processing;
    $one->set_command_class('App::Yath::Command::xxx_c');
    like(
        $one->_command_options(),
        array {
            # Command specific
            item {description => 'xxx_c - c'};
            item {description => 'xxx_c - x'};

            # Parent
            item {description => 'xxx_b - b'};

            # Parent - parent
            item {description => 'xxx_a - a'};
            item {description => 'xxx_a - x'};    # Resolved later by _build_spec()

            # Command Categories
            item {description => '*cat - bat'};

            # Parent categories
            item {description => '*cat - baz'};
            # bat was already brought in by out category list, so not here

            # Parent - parent categories
            item {description => '*cat - foo'};
            item {description => '*cat - bar'};

            # Globals
            item {description => '* - x'};    # This conflict gets removed in _build_spec()
            item {description => '* - y'};

            end;
        },
        "Got expected options for command xxx_c"
    );
};

subtest build_lookup => sub {
    my $one = $CLASS->new();

    my $opts;

    {
        package App::Yath;
        $opts = [
            $one->option('foo', type => 's', short => 'f', alt => ['fooo',  'fo']),
            $one->option('bar', type => 'b', short => 'b', alt => ['baar',  'br']),
        ];

        package App::Yath::Command::xxx;
        our @ISA = ('App::Yath::Command');

        push @$opts => (
            $one->option('foo2', type => 's', short => 'f', alt => ['foo', 'fooo']),
            $one->option('foo', prefix => 'pre', type => 's', alt => ['fooo', 'fo']),
        );
    }

    # Duplicate the opts, we should have no issues
    push @$opts => @$opts;

    my $lookup = $one->_build_lookup($opts);

    is(
        $lookup,
        {
            short => {
                f => exact_ref($opts->[0]),
                b => exact_ref($opts->[1]),
                # Third arg had a conflict of short, so it was omitted
                # fourth arg had a conflict of short, so it was omitted
            },
            long => {
                foo  => exact_ref($opts->[0]),
                fooo => exact_ref($opts->[0]),
                fo   => exact_ref($opts->[0]),

                bar  => exact_ref($opts->[1]),
                baar => exact_ref($opts->[1]),
                br   => exact_ref($opts->[1]),

                foo2 => exact_ref($opts->[2]),

                'pre-foo' => exact_ref($opts->[3]),
            },
        },
        "Lookup is as desired"
    );
};
subtest grab_command_opts => sub {
    my $one = $CLASS->new();

    my $opts = [
        App::Yath::Option->new(field => 'foo',     short => 'f', type => 's'),
        App::Yath::Option->new(field => 'bar-baz', short => 'b', type => 'm'),
        App::Yath::Option->new(field => 'xxx',     short => 'x', type => 'b'),
        App::Yath::Option->new(field => 'ccc',     short => 'c', type => 'c'),
        App::Yath::Option->new(field => 'ddd',     short => 'd', type => 'd'),
        App::Yath::Option->new(field => 'DDD',     short => 'D', type => 'D'),
    ];

    my $control = mock $CLASS => (
        override => [ _command_options => sub { $opts } ],
    );

    my $args = ['--foo' => 'fv', '-b=a', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_command_class('App::Yath::Command');
    $one->set_args($args);
    $one->grab_command_opts();
    is(
        $one->pending_cmd,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],

            [exact_ref($opts->[1]), 'handle', 'a'],

            [exact_ref($opts->[1]), 'handle', 'b'],

            [exact_ref($opts->[2]), 'handle', 1],

            [exact_ref($opts->[3]), 'handle', 1],
            [exact_ref($opts->[3]), 'handle', 1],

            [exact_ref($opts->[4]), 'handle', 1],
            [exact_ref($opts->[5]), 'handle', 1],

            [exact_ref($opts->[5]), 'handle', 'dv'],

            [exact_ref($opts->[2]), 'handle_negation'],
        ],
        "Processed all options"
    );
    is($args, ['nonopt', 'another_non_opt'], "Kept non-options in args array");

    $args = ['--foo' => 'fv', '-b=a', '--', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->set_command_class('App::Yath::Command');
    $one->grab_command_opts();
    is(
        $one->pending_cmd,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '--'"
    );
    is($args, ['-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after '--'");

    $args = ['--foo' => 'fv', '-b=a', '::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'];
    $one->reset_processing();
    $one->set_args($args);
    $one->set_command_class('App::Yath::Command');
    $one->grab_command_opts();
    is(
        $one->pending_cmd,
        [
            [exact_ref($opts->[0]), 'handle', 'fv'],
            [exact_ref($opts->[1]), 'handle', 'a'],
        ],
        "Stopped at '::'"
    );
    is($args, ['::', '-b' => 'b', 'nonopt', '-x', '-ccd', '-D', '-Ddv', '--no-xxx', 'another_non_opt'], "Kept everything after and including '::'");

    $args = ['-z'];
    $one->reset_processing();
    $one->set_args($args);
    $one->set_command_class('App::Yath::Command::xxx');
    is(
        dies { $one->grab_command_opts() },
        "Invalid command (xxx) option: -z\n",
        "Die for invalid option"
    );
};

subtest command_class => sub {
    my $one = $CLASS->new();

    $one->set_command_class('App::Yath::Command');
    is($one->command_class, 'App::Yath::Command', "Set via class name");

    $one->reset_processing();
    $one->set_command_class(bless {}, 'App::Yath::Command');
    is($one->command_class, 'App::Yath::Command', "Set via blessed command");

    like(
        dies { $one->set_command_class('foo') },
        qr/Command class has already been set/,
        "Cannot change command class without a full reset"
    );

    $one->reset_processing();
    like(
        dies { $one->set_command_class('foo') },
        qr/Invalid command class: foo/,
        "Must have a valid command class"
    );

};


