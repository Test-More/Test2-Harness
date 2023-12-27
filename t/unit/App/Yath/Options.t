use Test2::V0 -target => 'App::Yath::Options';
require App::Yath::Command;

subtest sugar => sub {
    package Test::Options::One;
    use App::Yath::Options;
    use Test2::V0 -target => 'App::Yath::Options';

    imported_ok(qw/post option options option_group include_options/);

    like(
        dies { $CLASS->import() },
        qr/Test::Options::One already has an 'options' method/,
        "Cannot double-import"
    );

    isa_ok(options(), [$CLASS], "options() returns an instance");

    my $line;
    option_group {prefix => 'foo'}, sub {
        option_group {category => 'uhg'}, sub {
            $line = __LINE__;
            option 'xxx'   => (description => 'xxx');
            option 'a_foo' => (description => 'a foo');
        };
        option 'outer' => (description => 'outer');
    };

    is(
        options()->all,
        [
            {
                type        => 'b',
                description => 'xxx',
                field       => 'xxx',
                name        => 'xxx',
                prefix      => 'foo',
                title       => 'xxx',
                category    => 'uhg',
                trace       => [__PACKAGE__, __FILE__, $line + 1],
            },
            {
                type        => 'b',
                description => 'a foo',
                field       => 'a_foo',
                name        => 'a-foo',
                prefix      => 'foo',
                title       => 'a_foo',
                category    => 'uhg',
                trace       => [__PACKAGE__, __FILE__, $line + 2],
            },
            {
                type        => 'b',
                description => 'outer',
                field       => 'outer',
                name        => 'outer',
                prefix      => 'foo',
                title       => 'outer',
                category    => 'NO CATEGORY - FIX ME',
                trace       => [__PACKAGE__, __FILE__, $line + 4],
            },
        ],
        "Added options, correct traces, prefix from group, nestable",
    );

    like(
        dies { option_group { builds => 'A::Fake::Module::Name' }, sub { 1 } },
        qr/Can't locate A.+Fake.+Module.+Name\.pm/,
        "'builds' must be a valid module"
    );

    post foo => sub { 1 };
    post bar => sub { 'app-a' }, sub { 2 };
    option_group {applicable => sub { 'app-b' } }, sub { post baz => sub { 3 } };

    my $posts = options->post_list;
    like(
        $posts,
        [
            ['foo'],
            ['bar'],
            ['baz'],
        ],
        "All 3 posts were listed"
    );
    is($posts->[0]->[1], undef, "No applicability check for foo");
    is($posts->[0]->[2]->(), 1, "Correct callback for foo");
    is($posts->[1]->[1]->(), 'app-a', "correct applicability check for bar");
    is($posts->[1]->[2]->(), 2, "Correct callback fo bar");
    is($posts->[2]->[1]->(), 'app-b', "correct applicability check for baz (from group)");
    is($posts->[2]->[2]->(), 3, "Correct callback fo baz");

    like(
        dies { post foo => 1 },
        qr/You must provide a callback coderef/,
        "Code is required"
    );

    package Test::Options::Two;
    use App::Yath::Options;
    use Test2::V0 -target => 'App::Yath::Options';

    include_options 'Test::Options::One';

    is(options()->all(), Test::Options::One->options()->all(), "Included options");
};

subtest init => sub {
    my $one = $CLASS->new();
    isa_ok($one, [$CLASS], "Created an instance");

    can_ok(
        $one,
        [qw{
            all lookup pre_list cmd_list post_list post_list_sorted settings args
            command_class pending_pre pending_cmd pending_post included set_by_cli
        }],
        "Attributes"
    );

    like(
        $one,
        {
            all        => [],
            lookup     => {},
            pre_list   => [],
            cmd_list   => [],
            post_list  => [],
            included   => {},
            set_by_cli => {},
        },
        "Set defaults",
    );

    isa_ok($one->settings, ['Test2::Harness::Settings'], "Generated a settings object by default");
};

subtest option => sub {
    my $one = $CLASS->new();

    my $trace = [__PACKAGE__, __FILE__, __LINE__ + 1];
    my $opt = $one->option('foo', prefix => 'pre');
    isa_ok($opt, ['App::Yath::Option'], "Got an option instance");
    is($opt->trace, $trace, "Injected the correct trace");
    is($opt->title, 'foo', "Correct title");
    is($opt->prefix, 'pre', "Correct prefix");
    is($one->all, [exact_ref($opt)], "Added the option");
    is($one->cmd_list, [exact_ref($opt)], "Added the option for commands");
    is($one->lookup, {foo => exact_ref($opt)}, "Added option to the lookup");
};

subtest _option => sub {
    my $one = $CLASS->new();

    my $trace = [__PACKAGE__, __FILE__, __LINE__ + 1];
    my $opt = $one->_option($trace, 'foo', prefix => 'pre');
    isa_ok($opt, ['App::Yath::Option'], "Got an option instance");
    is($opt->trace, $trace, "Used the correct trace");
    is($opt->title, 'foo', "Correct title");
    is($opt->prefix, 'pre', "Correct prefix");
    is($one->all, [exact_ref($opt)], "Added the option");
    is($one->cmd_list, [exact_ref($opt)], "Added the option for commands");
    is($one->lookup, {foo => exact_ref($opt)}, "Added option to the lookup");
};

subtest _parse_option_args => sub {
    my $one = $CLASS->new();

    is(
        {$one->_parse_option_args('foo')},
        {title => 'foo', type => undef},
        "Parse just title"
    );

    is(
        {$one->_parse_option_args('foo=b')},
        {title => 'foo', type => 'b'},
        "Parse title=type"
    );

    is(
        {$one->_parse_option_args('foo', 'b')},
        {title => 'foo', type => 'b'},
        "Parse title, type"
    );

    is(
        {$one->_parse_option_args('foo', type => 'b', other => 'yes')},
        {title => 'foo', type => 'b', other => 'yes'},
        "Parse title, %opts"
    );
};

subtest _parse_option_caller => sub {
    no warnings 'once';
    local *My::Caller::A::option_prefix = sub { 'MyPrefix' };
    my $one = $CLASS->new();

    is(
        {$one->_parse_option_caller('My::Caller::A', {})},
        {prefix => 'myprefix'},
        "Found prefix from package, and lowercased it"
    );

    is(
        {$one->_parse_option_caller('FAKE', {prefix => 'MyPrefix'})},
        {prefix => 'myprefix'},
        "Found prefix from proto, and lowercased it"
    );

    like(
        dies { $one->_parse_option_caller('FAKE', {title => 'foo'}) },
        qr/Could not find an option prefix and option is not top-level \(foo\)/,
        "Need a prefix"
    );

    local @App::Yath::Command::fake::ISA = ('App::Yath::Command');
    local *App::Yath::Command::fake::name = sub { 'fake' };
    is(
        {$one->_parse_option_caller('App::Yath::Command::fake')},
        {from_command => 'fake'},
        "Found command, prefix not required"
    );

    is(
        {$one->_parse_option_caller('App::Yath::Command::fake::Options::Foo')},
        {from_command => 'fake'},
        "Found command (options class for command), prefix not required"
    );

    is(
        {$one->_parse_option_caller('App::Yath')},
        {},
        "Special case, prefix not required for App::Yath namespace"
    );

    is(
        {$one->_parse_option_caller('App::Yath::Plugin::Foo')},
        {from_plugin => 'App::Yath::Plugin::Foo', prefix => 'foo'},
        "Automatic prefix for plugin"
    );
    is(
        {$one->_parse_option_caller('App::Yath::Plugin::Foo', {prefix => 'bar'})},
        {from_plugin => 'App::Yath::Plugin::Foo', prefix => 'bar'},
        "Can override automatic plugin prefix"
    );
};

subtest include_option => sub {
    my $one = $CLASS->new();

    like(
        dies { $one->include_option(bless({title => 'foo', prefix => 'pre'}, 'App::Yath::Option')) },
        qr/Options must have a trace/,
        "Need a trace"
    );

    my $opt = App::Yath::Option->new(title => 'foo', prefix => 'foo');
    is($one->include_option($opt), exact_ref($opt), "Added, and returned the reference");

    like(
        $one,
        {
            lookup   => {foo => exact_ref($opt)},
            all      => [exact_ref($opt)],
            cmd_list => [exact_ref($opt)],
        },
        "Added the option and indexed it"
    );
};

subtest _index_option => sub {
    my $one = $CLASS->new();
    my $opt1 = App::Yath::Option->new(title => 'foo', short => 'f', alt => ['fooo', 'fo'], prefix => 'foo');
    my $opt2 = App::Yath::Option->new(title => 'boo', short => 'b', alt => ['booo', 'bo'], prefix => 'foo');

    is($one->_index_option($opt1), 4, "indexed into 4 slots");
    is($one->_index_option($opt1), 0, "Double indexing the same opt does not explode, 0 slots");
    is(
        $one->lookup,
        {
            f    => exact_ref($opt1),
            fo   => exact_ref($opt1),
            foo  => exact_ref($opt1),
            fooo => exact_ref($opt1),
        },
        "Index has all 4 items",
    );

    is($one->_index_option($opt2), 4, "indexed into 4 slots");
    is($one->_index_option($opt2), 0, "Double indexing the same opt does not explode, 0 slots");
    is(
        $one->lookup,
        {
            f    => exact_ref($opt1),
            fo   => exact_ref($opt1),
            foo  => exact_ref($opt1),
            fooo => exact_ref($opt1),
            b    => exact_ref($opt2),
            bo   => exact_ref($opt2),
            boo  => exact_ref($opt2),
            booo => exact_ref($opt2),
        },
        "Index has all items",
    );

    my $string = $opt1->trace_string;
    like(
        dies { $one->_index_option(App::Yath::Option->new(title => 'foo', prefix => 'foo')) },
        qr/Option 'foo' was already defined \(\Q$string\E\)/,
        "Cannot add 2 opts with the same long flag"
    );
    like(
        dies { $one->_index_option(App::Yath::Option->new(title => 'xoo', alt => ['fo'], prefix => 'foo')) },
        qr/Option 'fo' was already defined \(\Q$string\E\)/,
        "Cannot add 2 opts with the same long flag (alt)"
    );
    like(
        dies { $one->_index_option(App::Yath::Option->new(title => 'zoo', short => 'f', prefix => 'foo')) },
        qr/Option 'f' was already defined \(\Q$string\E\)/,
        "Cannot add 2 opts with the same short flag"
    );
};

subtest _list_option => sub {
    my $one = $CLASS->new();
    my $opt1 = App::Yath::Option->new(title => 'foo', prefix => 'xxx');
    my $opt2 = App::Yath::Option->new(title => 'bar', prefix => 'xxx', pre_command => 1);

    ok($one->_list_option($opt1), "listed option 1");
    ok($one->_list_option($opt2), "listed option 2");

    like(
        $one,
        {
            cmd_list => [exact_ref($opt1)],
            pre_list => [exact_ref($opt2)],
        },
        "Added both options to the correct lists"
    );
};

subtest include => sub {
    my $one = $CLASS->new(post_list_sorted => 1);

    like(
        dies { $one->include() },
        qr/Include must be an instance of $CLASS, got undef/,
        "Must specify what to include"
    );

    like(
        dies { $one->include('foo') },
        qr/Include must be an instance of $CLASS, got 'foo'/,
        "String is not a valid include"
    );

    like(
        dies { $one->include($CLASS) },
        qr/Include must be an instance of $CLASS, got '$CLASS'/,
        "Package is not a valid include"
    );

    my $ref = [];
    like(
        dies { $one->include($ref) },
        qr/Include must be an instance of $CLASS, got '\Q$ref\E'/,
        "A reference is not a valid include"
    );

    bless $ref, 'XXX';
    like(
        dies { $one->include($ref) },
        qr/Include must be an instance of $CLASS, got '\Q$ref\E'/,
        "Must be an instance of $CLASS"
    );

    my $two = $CLASS->new();
    my $opt1 = $two->option('foo', prefix => 'bar');
    my $opt2 = $two->option('baz', prefix => 'bar', pre_command => 1);
    my $post = sub { 1 };
    $two->_post(1, undef, $post);

    $one->include($two);
    like(
        $one,
        {
            post_list_sorted => F(),
            post_list        => [[1, undef, exact_ref($post)]],
            cmd_list         => [exact_ref($opt1)],
            pre_list         => [exact_ref($opt2)],
            all              => [exact_ref($opt1), exact_ref($opt2)],
            lookup           => {baz => exact_ref($opt2), foo => exact_ref($opt1)},
        },
        "Included options and post-callbacks from the second instance"
    );
};

subtest include_from => sub {
    my $one = $CLASS->new(post_list_sorted => 1);

    my $two = $CLASS->new();
    my $opt1 = $two->option('foo', prefix => 'bar');
    my $opt2 = $two->option('baz', prefix => 'bar', pre_command => 1);
    my $post = sub { 1 };
    $two->_post(1, undef, $post);
    $two->included->{'fake'} = 2;

    no warnings 'once';
    *Some::Fake::Package::options = sub { $two };

    $one->include_from('Some::Fake::Package');
    like(
        $one,
        {
            post_list_sorted => F(),
            post_list        => [[1, undef, exact_ref($post)]],
            cmd_list         => [exact_ref($opt1)],
            pre_list         => [exact_ref($opt2)],
            all              => [exact_ref($opt1), exact_ref($opt2)],
            lookup           => {baz => exact_ref($opt2), foo => exact_ref($opt1)},
            included         => {'fake' => T(), 'Some::Fake::Package' => T()},
        },
        "Included options and post-callbacks from the specified package"
    );

    like(
        dies { $one->include_from('Some::Other::Package') },
        qr/Can't locate Some.+Other.+Package\.pm in \@INC/,
        "Must be a valid package"
    );
};

subtest populate_pre_defaults => sub {
    my $one = $CLASS->new();

    $one->option('noo', prefix => 'x', type => 's');
    $one->option('foo', prefix => 'x', pre_command => 1, type => 's');
    $one->option('bar', prefix => 'x', pre_command => 1, type => 'h');
    $one->option('baz', prefix => 'x', pre_command => 1, type => 's', default => 42);
    $one->option('bat', prefix => 'x', pre_command => 1, type => 'm', default => sub { [42] });
    $one->option('ban', prefix => 'x', pre_command => 1, type => 'h', default => sub { {answer => 42} });
    $one->option('bag', prefix => 'x', pre_command => 1, type => 's', default => sub { });

    $one->populate_pre_defaults();

    is(
        ${$one->settings->x},
        {
            baz => 42,
            bar => {},
            bat => [42],
            ban => {answer => 42},

            # The field itself is vivified, but no value set, thus it is undef
            # This prevents $settings->x->foo from exploding
            foo => undef,

            # Default returned an empty list, just vivify, maybe they know what
            # they are doing?
            bag => undef,

            # Be explicit, this should NOT be populated, not even as undef
            noo => DNE(),
        },
        "Populated fields as expected",
    );
};

subtest populate_cmd_defaults => sub {
    my $one = $CLASS->new();

    $one->option('noo', prefix => 'x', pre_command => 1, type => 's');
    $one->option('foo', prefix => 'x', type => 's');
    $one->option('bar', prefix => 'x', type => 'h');
    $one->option('baz', prefix => 'x', type => 's', default => 42);
    $one->option('bat', prefix => 'x', type => 'm', default => sub { [42] });
    $one->option('ban', prefix => 'x', type => 'h', default => sub { {answer => 42} });
    $one->option('bag', prefix => 'x', type => 's', default => sub { });

    like(
        dies { $one->populate_cmd_defaults() },
        qr/The 'command_class' attribute has not yet been set/,
        "Need to set command class first"
    );

    push @App::Yath::Command::fake::ISA => 'App::Yath::Command';
    $one->set_command_class('App::Yath::Command::fake');
    $one->populate_cmd_defaults();

    is(
        ${$one->settings->x},
        {
            baz => 42,
            bar => {},
            bat => [42],
            ban => {answer => 42},

            # The field itself is vivified, but no value set, thus it is undef
            # This prevents $settings->x->foo from exploding
            foo => undef,

            # Default returned an empty list, just vivify, maybe they know what
            # they are doing?
            bag => undef,

            # We also process any remaining pre-command ops
            noo => undef,
        },
        "Populated fields as expected",
    );
};

subtest set_args => sub {
    my $one = $CLASS->new();

    ok(!$one->args, "No args yet");

    $one->set_args(['foo', 'bar']);
    is($one->args, ['foo', 'bar'], "Set the args");

    like(
        dies { $one->set_args(['a']) },
        qr/'args' has already been set/,
        "Cannot set args a second time",
    );

    is($one->args, ['foo', 'bar'], "Args did not change");
};

subtest _grab_opts => sub {
    my $one = $CLASS->new();

    like(
        dies { $one->_grab_opts() },
        qr/The opt_fetch callback is required/,
        "Need opts"
    );

    like(
        dies { $one->_grab_opts(sub {[]}) },
        qr/The arg type is required/,
        "Need arg type"
    );

    like(
        dies { $one->_grab_opts(sub {[]}, 'blah') },
        qr/The 'args' attribute has not yet been set/,
        "Need args"
    );

    $one = $CLASS->new;
    my $opt1 = $one->option('foo', prefix => 'x', type => 'b', short   => 'f');
    my $opt2 = $one->option('bar', prefix => 'x', type => 'b', alt     => ['ba']);
    my $opt3 = $one->option('baz', prefix => 'x', type => 's');
    my $opt4 = $one->option('bat', prefix => 'x', type => 'm');
    my $opt5 = $one->option('ban', prefix => 'x', type => 'd');

    $one->{args} = ['-f', '--ba', 'xxx', '--baz=uhg', '--bat', 'a', '--no-foo', '--bat', 'b', '--ban=y', '--ban', 'blah', '--', '--bat', 'NO'];
    my @out = $one->_grab_opts('all', 'foo');

    is($one->args, ['xxx', 'blah', '--', '--bat', 'NO'], "Pulled out known args, stopped at --");
    is(
        \@out,
        [
            [exact_ref($opt1), 'handle', 1],
            [exact_ref($opt2), 'handle', 1],
            [exact_ref($opt3), 'handle', 'uhg'],
            [exact_ref($opt4), 'handle', 'a'],
            [exact_ref($opt1), 'handle_negation'],
            [exact_ref($opt4), 'handle', 'b'],
            [exact_ref($opt5), 'handle', 'y'],
            [exact_ref($opt5), 'handle', 1],
        ],
        "Got actions to take"
    );

    $one->{args} = ['-f', '--ba', 'xxx', '--baz=uhg', '--bat', 'a', '--no-foo', '--bat', 'b', '--ban=y', '--ban', 'blah', '::', '--bat', 'NO'];
    @out = $one->_grab_opts('all', 'foo');

    is($one->args, ['xxx', 'blah', '::', '--bat', 'NO'], "Pulled out known args, stopped at ::");
    is(
        \@out,
        [
            [exact_ref($opt1), 'handle', 1],
            [exact_ref($opt2), 'handle', 1],
            [exact_ref($opt3), 'handle', 'uhg'],
            [exact_ref($opt4), 'handle', 'a'],
            [exact_ref($opt1), 'handle_negation'],
            [exact_ref($opt4), 'handle', 'b'],
            [exact_ref($opt5), 'handle', 'y'],
            [exact_ref($opt5), 'handle', 1],
        ],
        "Got actions to take"
    );

    $one->{args} = ['-f', '--ba', 'xxx', '--baz=uhg'];
    like(
        dies { $one->_grab_opts('all', 'foo', die_at_non_opt => 1) },
        qr/Invalid foo option: xxx/,
        "Died at non-opt",
    );

    $one->{args} = ['-f', '--ba', 'xxx', '--xyz', '--baz=uhg'];
    like(
        dies { $one->_grab_opts('all', 'foo') },
        qr/Invalid foo option: --xyz/,
        "Died at invalid opt",
    );

    $one->{args} = ['-f', '--ba', 'xxx', '--xyz', '--baz=uhg'];
    @out = $one->_grab_opts('all', 'foo', passthrough => 1);

    is($one->args, ['xxx', '--xyz'], "Pulled out known args");
    is(
        \@out,
        [
            [exact_ref($opt1), 'handle', 1],
            [exact_ref($opt2), 'handle', 1],
            [exact_ref($opt3), 'handle', 'uhg'],
        ],
        "Got actions to take"
    );
};

subtest '*_command_opts' => sub {
    my $set_def = 0;
    my $control = mock $CLASS => (
        override => [
            populate_cmd_defaults => sub { $set_def++ },
        ],
    );
    my $one = $CLASS->new();
    $one->set_command_class('App::Yath::Command');

    my $opt1 = $one->option('foo', prefix => 'x', type => 'b', short   => 'f');
    my $opt2 = $one->option('bar', prefix => 'x', type => 'b', alt     => ['ba']);
    my $opt3 = $one->option('baz', prefix => 'x', type => 's');
    my $opt4 = $one->option('bat', prefix => 'x', type => 'm');
    my $opt5 = $one->option('ban', prefix => 'x', type => 'D');
    my $opt6 = $one->option('bag', prefix => 'x', type => 's', pre_command => 1);

    $one->{args} = ['-f', '--ba', 'xxx', '--bag=yes', '--baz=uhg', '--bat', 'a', '--no-foo', '--bat', 'b', '--ban=y', '--ban', 'blah', '--', '--bat', 'NO'];
    $one->grab_command_opts($one->all, 'foo');

    is($one->args, ['xxx', 'blah', '--', '--bat', 'NO'], "Pulled out known args, stopped at --");
    is(
        $one->pending_cmd,
        [
            [exact_ref($opt1), 'handle', 1],
            [exact_ref($opt2), 'handle', 1],
            [exact_ref($opt6), 'handle', 'yes'],
            [exact_ref($opt3), 'handle', 'uhg'],
            [exact_ref($opt4), 'handle', 'a'],
            [exact_ref($opt1), 'handle_negation'],
            [exact_ref($opt4), 'handle', 'b'],
            [exact_ref($opt5), 'handle', 'y'],
            [exact_ref($opt5), 'handle', 1],
        ],
        "Got actions to take, including pre-command options that were not processed yet"
    );

    $one->process_command_opts;

    is($one->pending_cmd, undef, "Nothing left to do");

    is(
        ${$one->settings->x},
        {
            foo => FDNE(),
            bar => T(),
            baz => 'uhg',
            bat => ['a', 'b'],
            ban => ['y', 1],
            bag => 'yes',
        },
        "Set the proper settings"
    );
};

subtest '*_pre_command_opts' => sub {
    my $set_def = 0;
    my $control = mock $CLASS => (
        override => [
            populate_pre_defaults => sub { $set_def++ },
        ],
    );
    my $one = $CLASS->new();

    my $opt1 = $one->option('foo', pre_command => 1, prefix => 'x', type => 'b', short   => 'f');
    my $opt2 = $one->option('bar', pre_command => 1, prefix => 'x', type => 'b', alt     => ['ba']);
    my $opt3 = $one->option('baz', pre_command => 1, prefix => 'x', type => 's');
    my $opt4 = $one->option('bat', pre_command => 1, prefix => 'x', type => 'm');
    my $opt5 = $one->option('ban', pre_command => 1, prefix => 'x', type => 'D');
    my $opt6 = $one->option('bag', pre_command => 0, prefix => 'x', type => 'd');

    $one->{args} = ['-f', '--ba', '--baz=uhg', '--bat', 'a', '--no-foo', '--bat', 'b', '--ban=y', '--ban', '--bag=yes', 'xxx', 'blah', '--bat', 'NO'];
    $one->grab_pre_command_opts($one->all, 'foo');

    is($one->args, ['--bag=yes', 'xxx', 'blah', '--bat', 'NO'], "Pulled out known args, stopped at non-opt");
    is(
        $one->pending_pre,
        [
            [exact_ref($opt1), 'handle', 1],
            [exact_ref($opt2), 'handle', 1],
            [exact_ref($opt3), 'handle', 'uhg'],
            [exact_ref($opt4), 'handle', 'a'],
            [exact_ref($opt1), 'handle_negation'],
            [exact_ref($opt4), 'handle', 'b'],
            [exact_ref($opt5), 'handle', 'y'],
            [exact_ref($opt5), 'handle', 1],
        ],
        "Got actions to take, did not grab command options"
    );

    $one->process_pre_command_opts;

    is($one->pending_pre, undef, "Nothing left to do");

    is(
        ${$one->settings->x},
        {
            foo => FDNE(),
            bar => T(),
            baz => 'uhg',
            bat => ['a', 'b'],
            ban => ['y', 1],
            bag => DNE(),
        },
        "Set the proper settings"
    );
};

subtest set_command_class => sub {
    my $one = $CLASS->new();

    ok(!$one->command_class, "No command class yet");

    require App::Yath::Command::test;
    my $cmd = bless {}, 'App::Yath::Command::test';
    $one->set_command_class($cmd);
    is($one->command_class, 'App::Yath::Command::test', "Can set via a blessed command instance");

    like(
        dies { $one->set_command_class() },
        qr/Command class has already been set/,
        "Cannot change command class once set."
    );

    ok($one->included->{'App::Yath::Command::test'}, "Included options from the command");

    $one = $CLASS->new();
    $one->set_command_class('App::Yath::Command::test');
    is($one->command_class, 'App::Yath::Command::test', "Can set via a class name");

    $one = $CLASS->new();
    like(
        dies { $one->set_command_class('Test2::Harness::Util') },
        qr/Invalid command class: Test2::Harness::Util/,
        "Must be a valid command class"
    );
};

subtest post => sub {
    my $one = $CLASS->new(post_list_sorted => 1);

    my $sub = sub { 'foo' };
    $one->_post(undef, undef, $sub);
    ok(!$one->post_list_sorted, "List is no longer considered sorted when we add an item");
    is($one->post_list, [[0, undef, exact_ref($sub)]], "Added item to post list");

    like(
        dies { $one->process_option_post_actions },
        qr/The 'args' attribute has not yet been set/,
        "Need args first"
    );

    $one = $CLASS->new();
    $one->set_args(['foo']);
};

done_testing;
