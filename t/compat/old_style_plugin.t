use Test2::V0;
use Test2::Harness::Settings;

# ============================================================
# 1. Old-style plugin package using App::Yath::Options
# ============================================================
{
    package TestOldPlugin;
    use App::Yath::Options;

    option_group {prefix => 'testold', category => 'Test Old'} => sub {
        option verbose => (description => 'Be verbose');                       # bare bool (no type => defaults to 'b')
        option count   => (type => 'c', description => 'Count');              # count
        option name    => (type => 's', description => 'Name', default => 'default');  # scalar
        option items   => (type => 'm', description => 'Items');              # list
        option pairs   => (type => 'h', description => 'Pairs');             # map
        option auto_val => (type => 'd', description => 'Auto value', autofill => 'auto');  # auto (optional arg)
    };

    my $POST_CALLED = 0;
    sub post_called { $POST_CALLED }
    sub reset_post  { $POST_CALLED = 0 }

    post sub {
        my %params = @_;
        $POST_CALLED++;
    };
}

# ============================================================
# 2. New-style plugin package using Getopt::Yath
# ============================================================
{
    package TestNewPlugin;
    use Getopt::Yath;

    option_group {group => 'testnew', category => 'Test New'} => sub {
        option debug => (type => 'Bool',   description => 'Debug mode',  no_module => 1);
        option level => (type => 'Scalar', description => 'Level',       default   => '1', no_module => 1);
        option tags  => (type => 'List',   description => 'Tags',        no_module => 1);
    };
}

# ============================================================
# 3. Include both into a single App::Yath::Options and verify
# ============================================================
subtest 'Include both old and new style plugins' => sub {
    my $options = App::Yath::Options->new();

    ok(lives { $options->include_from('TestOldPlugin') }, "include_from old-style plugin succeeds");
    ok(lives { $options->include_from('TestNewPlugin') }, "include_from new-style plugin succeeds");

    # Check that both packages are tracked
    ok($options->included->{'TestOldPlugin'}, "TestOldPlugin tracked in included");
    ok($options->included->{'TestNewPlugin'}, "TestNewPlugin tracked in included");

    # All options from both packages are present
    my $lookup = $options->lookup;
    ok($lookup->{verbose},  "Old-style 'verbose' option in lookup");
    ok($lookup->{count},    "Old-style 'count' option in lookup");
    ok($lookup->{name},     "Old-style 'name' option in lookup");
    ok($lookup->{items},    "Old-style 'items' option in lookup");
    ok($lookup->{pairs},    "Old-style 'pairs' option in lookup");
    ok($lookup->{auto_val} || $lookup->{'auto-val'}, "Old-style 'auto_val' option in lookup");
    ok($lookup->{debug},    "New-style 'debug' option in lookup");
    ok($lookup->{level},    "New-style 'level' option in lookup");
    ok($lookup->{tags},     "New-style 'tags' option in lookup");

    my @all = @{$options->all};
    ok(scalar @all >= 9, "At least 9 options included (got " . scalar(@all) . ")");
};

# ============================================================
# 4. Parse command-line arguments end-to-end
# ============================================================
subtest 'End-to-end parse from command-line args' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');
    $options->include_from('TestNewPlugin');

    # Populate defaults for all options
    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($options->settings);
        my $val  = $opt->get_default($options->settings);
        $$slot //= $val;
    }

    my $settings = $options->settings;

    # Verify defaults before parsing
    is($settings->testold->name, 'default', "Scalar default applied before parsing");
    is($settings->testnew->level, '1', "New-style scalar default applied");

    # Set up args to parse
    my $auto_flag = '--auto-val';
    my @args = (
        '--verbose',
        '--count', '--count', '--count',       # 3 increments
        '--name', 'myname',
        '--items', 'a', '--items', 'b', '--items', 'c',
        '--pairs', 'x=1', '--pairs', 'y=2',
        $auto_flag,                            # auto with no arg -> uses autofill
        '--debug',
        '--level', '5',
        '--tags', 'fast', '--tags', 'unit',
        'remaining_arg',
    );

    $options->{args} = \@args;

    my @grabbed = $options->_grab_opts('all', 'test', passthrough => 1);
    ok(@grabbed > 0, "Grabbed option actions from args");
    is(\@args, ['remaining_arg'], "Non-option arg remains after parsing");

    # Process grabbed opts
    for my $opt_set (@grabbed) {
        my ($opt, $meth, @vals) = @$opt_set;
        $opt->$meth(@vals, $settings, $options, []);
    }

    # Verify old-style results
    is($settings->testold->verbose, 1, "Bool verbose set to 1");
    is($settings->testold->count, 3, "Count incremented 3 times");
    is($settings->testold->name, 'myname', "Scalar name set");
    is($settings->testold->items, ['a', 'b', 'c'], "List items set");

    # Map includes '@' ordering key
    is($settings->testold->pairs, {x => '1', y => '2', '@' => ['x', 'y']}, "Map pairs set with ordering");

    is($settings->testold->auto_val, 'auto', "Auto option used autofill value");

    # Verify new-style results
    is($settings->testnew->debug, 1, "New-style bool debug set to 1");
    is($settings->testnew->level, '5', "New-style scalar level set to 5");
    is($settings->testnew->tags, ['fast', 'unit'], "New-style list tags set");
};

# ============================================================
# 5. Post callbacks fire correctly
# ============================================================
subtest 'Post callbacks fire' => sub {
    TestOldPlugin->reset_post();
    is(TestOldPlugin->post_called(), 0, "Post not yet called");

    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');

    # Populate defaults
    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($options->settings);
        my $val  = $opt->get_default($options->settings);
        $$slot //= $val;
    }

    # Set args (required by process_option_post_actions)
    $options->{args} = [];

    ok(scalar @{$options->post_list} >= 1, "Post list has callbacks");

    $options->process_option_post_actions(undef);
    ok(TestOldPlugin->post_called() > 0, "Post callback was fired");
};

# ============================================================
# 6. Settings compatibility tests
# ============================================================
subtest 'Settings compatibility' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');
    $options->include_from('TestNewPlugin');

    # Populate defaults
    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($options->settings);
        my $val  = $opt->get_default($options->settings);
        $$slot //= $val;
    }

    my $settings = $options->settings;

    # AUTOLOAD lvalue access
    $settings->testold->verbose = 1;
    is($settings->testold->verbose, 1, "AUTOLOAD lvalue set works");

    # define_prefix / vivify_field
    my $pfx = $settings->define_prefix('foo');
    isa_ok($pfx, ['Test2::Harness::Settings::Prefix'], "define_prefix returns Prefix");
    my $ref = $pfx->vivify_field('bar');
    $$ref = 'baz';
    is($pfx->bar, 'baz', "vivify_field + set works");

    # TO_JSON
    my $json = $settings->testold->TO_JSON;
    ref_ok($json, 'HASH', "TO_JSON returns a hashref");
    ok(exists $json->{verbose}, "TO_JSON includes 'verbose' field");
    ok(exists $json->{name}, "TO_JSON includes 'name' field");

    # build
    {
        $INC{'CompatBuildTarget.pm'} = __FILE__;
        package CompatBuildTarget;
        sub new { shift; bless {@_}, 'CompatBuildTarget' };
    }
    my $built = $settings->testold->build('CompatBuildTarget', extra => 'val');
    isa_ok($built, ['CompatBuildTarget'], "build creates correct class");
    is($built->{name}, 'default', "build passes prefix data");
    is($built->{extra}, 'val', "build passes extra args");

    # prefix() and group() both work
    is($settings->prefix('testold'), exact_ref($settings->testold), "prefix() returns same as AUTOLOAD");
    is($settings->group('testold'),  exact_ref($settings->testold), "group() returns same as AUTOLOAD");

    # check_prefix and check_group
    ok($settings->check_prefix('testold'), "check_prefix returns true for existing");
    ok($settings->check_group('testold'),  "check_group returns true for existing");
    ok(!$settings->check_prefix('nonexistent'), "check_prefix returns false for missing");
    ok(!$settings->check_group('nonexistent'),  "check_group returns false for missing");

    # Settings isa Getopt::Yath::Settings
    isa_ok($settings, ['Getopt::Yath::Settings'], "Settings isa Getopt::Yath::Settings");

    # Prefix isa Getopt::Yath::Settings::Group
    isa_ok($settings->testold, ['Test2::Harness::Settings::Prefix'], "Prefix is correct class");
    isa_ok($settings->testold, ['Getopt::Yath::Settings::Group'], "Prefix isa Settings::Group");
};

# ============================================================
# 7. Old option type codes work through the bridge
# ============================================================
subtest 'Old type codes through bridge' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');

    my $settings = $options->settings;

    # Initialize all slots
    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($settings);
        my $val  = $opt->get_default($settings);
        $$slot //= $val;
    }

    my $lookup = $options->lookup;

    # Find each option
    my $verbose_opt  = $lookup->{verbose};
    my $count_opt    = $lookup->{count};
    my $name_opt     = $lookup->{name};
    my $items_opt    = $lookup->{items};
    my $pairs_opt    = $lookup->{pairs};
    my $auto_val_opt = $lookup->{auto_val} || $lookup->{'auto-val'};

    # type 'b' -> Bool behavior
    ok($verbose_opt, "verbose option found");
    is($verbose_opt->type, 'b', "verbose has type 'b'");
    ok(!$verbose_opt->requires_arg, "Bool does not require arg");
    ok(!$verbose_opt->allows_arg, "Bool does not allow arg");
    $verbose_opt->handle(1, $settings, $options, []);
    is($settings->testold->verbose, 1, "Bool set to 1");
    $verbose_opt->handle_negation($settings, $options);
    is($settings->testold->verbose, 0, "Bool negated to 0");

    # type 'c' -> Count behavior
    ok($count_opt, "count option found");
    is($count_opt->type, 'c', "count has type 'c'");
    ok(!$count_opt->requires_arg, "Count does not require arg");
    $settings->testold->count = 0;
    $count_opt->handle(1, $settings, $options, []);
    $count_opt->handle(1, $settings, $options, []);
    $count_opt->handle(1, $settings, $options, []);
    is($settings->testold->count, 3, "Count incremented 3 times");
    $count_opt->handle_negation($settings, $options);
    is($settings->testold->count, 0, "Count negated to 0");

    # type 's' -> Scalar behavior
    ok($name_opt, "name option found");
    is($name_opt->type, 's', "name has type 's'");
    ok($name_opt->requires_arg, "Scalar requires arg");
    ok($name_opt->allows_arg, "Scalar allows arg");
    $name_opt->handle('newname', $settings, $options, []);
    is($settings->testold->name, 'newname', "Scalar set to new value");
    $name_opt->handle_negation($settings, $options);
    is($settings->testold->name, undef, "Scalar negated to undef");

    # type 'm' -> List behavior
    ok($items_opt, "items option found");
    is($items_opt->type, 'm', "items has type 'm'");
    ok($items_opt->requires_arg, "List requires arg");
    $settings->testold->items = [];
    $items_opt->handle('one', $settings, $options, []);
    $items_opt->handle('two', $settings, $options, []);
    is($settings->testold->items, ['one', 'two'], "List accumulated values");
    $items_opt->handle_negation($settings, $options);
    is($settings->testold->items, [], "List negated to empty");

    # type 'h' -> Map behavior
    ok($pairs_opt, "pairs option found");
    is($pairs_opt->type, 'h', "pairs has type 'h'");
    ok($pairs_opt->requires_arg, "Map requires arg");
    $settings->testold->pairs = {};
    $pairs_opt->handle('k1=v1', $settings, $options, []);
    $pairs_opt->handle('k2=v2', $settings, $options, []);
    is($settings->testold->pairs, {k1 => 'v1', k2 => 'v2', '@' => ['k1', 'k2']}, "Map set key=value pairs");
    $pairs_opt->handle_negation($settings, $options);
    is($settings->testold->pairs, {}, "Map negated to empty");

    # type 'd' -> Auto (optional arg) behavior
    ok($auto_val_opt, "auto_val option found");
    is($auto_val_opt->type, 'd', "auto_val has type 'd'");
    ok(!$auto_val_opt->requires_arg, "Auto does not require arg");
    ok($auto_val_opt->allows_arg, "Auto allows arg");
    is($auto_val_opt->autofill, 'auto', "Auto has correct autofill value");
};

# ============================================================
# 8. Negation via --no-* works for old-style options
# ============================================================
subtest 'Negation via --no-* flag parsing' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');

    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($options->settings);
        my $val  = $opt->get_default($options->settings);
        $$slot //= $val;
    }

    my @args = ('--verbose', '--no-verbose');
    $options->{args} = \@args;

    my @grabbed = $options->_grab_opts('all', 'test', passthrough => 1);

    for my $opt_set (@grabbed) {
        my ($opt, $meth, @vals) = @$opt_set;
        $opt->$meth(@vals, $options->settings, $options, []);
    }

    is($options->settings->testold->verbose, 0, "verbose set then negated via --no-verbose");
};

# ============================================================
# 9. Old-style option field names use underscore (not dash)
# ============================================================
subtest 'Field name normalization' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');

    my $lookup = $options->lookup;
    my $auto_opt = $lookup->{auto_val} || $lookup->{'auto-val'};
    ok($auto_opt, "auto_val option found in lookup");

    # The field should always use underscores
    is($auto_opt->field, 'auto_val', "Field uses underscores");
};

# ============================================================
# 10. include_from tracks included packages
# ============================================================
subtest 'include_from tracks packages' => sub {
    my $options = App::Yath::Options->new();
    $options->include_from('TestOldPlugin');

    ok($options->included->{'TestOldPlugin'}, "TestOldPlugin is tracked after include_from");
    ok($options->included->{'TestOldPlugin'} >= 1, "Included counter is at least 1");
};

done_testing;
