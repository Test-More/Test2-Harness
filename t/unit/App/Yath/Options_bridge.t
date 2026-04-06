use Test2::V0;
use App::Yath::Options;
use App::Yath::Option::Adapter;

# Create a package that uses Getopt::Yath DSL
{
    package Test::Bridge::GetoptPkg;
    use Getopt::Yath;

    option_group {group => 'runner'} => sub {
        option 'job-count' => (
            type        => 'Scalar',
            short       => 'j',
            description => 'Number of jobs to run concurrently',
            initialize  => 1,
        );

        option 'verbose' => (
            type        => 'Count',
            short       => 'v',
            description => 'Be more verbose',
        );

        option 'lib' => (
            type        => 'List',
            description => 'Add a directory to the library path',
            initialize  => sub { [] },
        );

        option 'switch' => (
            type        => 'Map',
            description => 'Key=Value switches',
        );

        option 'color' => (
            type        => 'Bool',
            description => 'Enable color output',
            initialize  => 1,
        );
    };

    option_post_process 10 => sub {
        my ($instance, $state) = @_;
        # Post callback placeholder
    };
}

subtest 'Getopt::Yath package returns Instance' => sub {
    my $opts = Test::Bridge::GetoptPkg->options;
    isa_ok($opts, ['Getopt::Yath::Instance'], "options() returns a Getopt::Yath::Instance");
    ok(scalar @{$opts->options} >= 5, "Has at least 5 options");
};

subtest 'Adapter wraps Getopt::Yath::Option correctly' => sub {
    my $inst = Test::Bridge::GetoptPkg->options;
    my @gy_opts = @{$inst->options};

    # Find the job-count option
    my ($jc_opt) = grep { $_->name eq 'job-count' } @gy_opts;
    ok($jc_opt, "Found job-count option in Getopt::Yath instance");

    my $adapter = App::Yath::Option::Adapter->new(inner => $jc_opt);

    is($adapter->name,   'job-count', "name is correct");
    is($adapter->field,  'job_count', "field is correct");
    is($adapter->short,  'j',         "short is correct");
    is($adapter->prefix, 'runner',    "prefix maps from group");
    is($adapter->type,   's',         "Scalar maps to type 's'");
    is($adapter->description, 'Number of jobs to run concurrently', "description passes through");

    ok($adapter->isa('App::Yath::Option'), "Adapter passes isa check for App::Yath::Option");
    ok($adapter->requires_arg, "Scalar type requires arg");
    ok($adapter->allows_arg,   "Scalar type allows arg");

    # Find the verbose (Count) option
    my ($v_opt) = grep { $_->name eq 'verbose' } @gy_opts;
    my $v_adapter = App::Yath::Option::Adapter->new(inner => $v_opt);
    is($v_adapter->type, 'c', "Count maps to type 'c'");
    is($v_adapter->short, 'v', "short is correct for verbose");

    # Find the lib (List) option
    my ($l_opt) = grep { $_->name eq 'lib' } @gy_opts;
    my $l_adapter = App::Yath::Option::Adapter->new(inner => $l_opt);
    is($l_adapter->type, 'm', "List maps to type 'm'");
    ok($l_adapter->requires_arg, "List type requires arg");

    # Find the switch (Map) option
    my ($m_opt) = grep { $_->name eq 'switch' } @gy_opts;
    my $m_adapter = App::Yath::Option::Adapter->new(inner => $m_opt);
    is($m_adapter->type, 'h', "Map maps to type 'h'");

    # Find the color (Bool) option
    my ($b_opt) = grep { $_->name eq 'color' } @gy_opts;
    my $b_adapter = App::Yath::Option::Adapter->new(inner => $b_opt);
    is($b_adapter->type, 'b', "Bool maps to type 'b'");
    ok(!$b_adapter->requires_arg, "Bool type does not require arg");
};

subtest 'include() accepts Getopt::Yath::Instance' => sub {
    my $options = App::Yath::Options->new();
    my $inst = Test::Bridge::GetoptPkg->options;

    ok(lives { $options->include($inst) }, "include() accepts Getopt::Yath::Instance without dying");

    my @all = @{$options->all};
    ok(scalar @all >= 5, "Included at least 5 options");

    # Verify they are adapters
    for my $opt (@all) {
        ok($opt->isa('App::Yath::Option'), "Adapter passes isa check");
        isa_ok($opt, ['App::Yath::Option::Adapter'], "Is an Adapter instance");
    }

    # Verify names are in the lookup
    my $lookup = $options->lookup;
    ok($lookup->{'job-count'}, "job-count is in the lookup");
    ok($lookup->{'verbose'},   "verbose is in the lookup");
    ok($lookup->{'lib'},       "lib is in the lookup");
    ok($lookup->{'switch'},    "switch is in the lookup");
    ok($lookup->{'color'},     "color is in the lookup");

    # Verify post callbacks were included
    my $posts = $options->post_list;
    ok(scalar @$posts >= 1, "Post callback was included");
};

subtest 'include_from() works with Getopt::Yath packages' => sub {
    my $options = App::Yath::Options->new();

    ok(lives { $options->include_from('Test::Bridge::GetoptPkg') }, "include_from works with Getopt::Yath package");

    my $included = $options->included;
    ok($included->{'Test::Bridge::GetoptPkg'}, "Package tracked in included hash");

    my @all = @{$options->all};
    ok(scalar @all >= 5, "Options were included");
};

subtest 'option_slot and handle work with Settings' => sub {
    my $options = App::Yath::Options->new();
    $options->include(Test::Bridge::GetoptPkg->options);

    my $settings = $options->settings;

    # Find the job-count adapter
    my ($jc_opt) = grep { $_->field eq 'job_count' } @{$options->all};
    ok($jc_opt, "Found job-count option");

    # option_slot should create the prefix and field
    my $slot = $jc_opt->option_slot($settings);
    ok(ref($slot) eq 'SCALAR' || ref($slot) eq 'REF', "option_slot returns a reference");

    # get_default should return the initialize value (1)
    my $default = $jc_opt->get_default($settings);
    is($default, 1, "get_default returns the initialize value");

    # Set the default
    $$slot = $default;
    is($$slot, 1, "Default value set via slot");

    # handle should set a new value
    $jc_opt->handle('8', $settings, $options, []);
    is(${$jc_opt->option_slot($settings)}, 8, "handle set the value to 8");

    # Test bool negation
    my ($color_opt) = grep { $_->field eq 'color' } @{$options->all};
    my $color_slot = $color_opt->option_slot($settings);
    $$color_slot = 1;
    $color_opt->handle_negation($settings, $options);
    is($$color_slot, 0, "handle_negation set bool to 0");

    # Test count
    my ($verbose_opt) = grep { $_->field eq 'verbose' } @{$options->all};
    my $verbose_slot = $verbose_opt->option_slot($settings);
    $$verbose_slot = 0;
    $verbose_opt->handle(1, $settings, $options, []);
    is($$verbose_slot, 1, "Count incremented to 1");
    $verbose_opt->handle(1, $settings, $options, []);
    is($$verbose_slot, 2, "Count incremented to 2");

    # Test list
    my ($lib_opt) = grep { $_->field eq 'lib' } @{$options->all};
    my $lib_slot = $lib_opt->option_slot($settings);
    $$lib_slot = [];
    $lib_opt->handle('/foo', $settings, $options, []);
    $lib_opt->handle('/bar', $settings, $options, []);
    is($$lib_slot, ['/foo', '/bar'], "List appended values");

    # Test map
    my ($switch_opt) = grep { $_->field eq 'switch' } @{$options->all};
    my $switch_slot = $switch_opt->option_slot($settings);
    $$switch_slot = {};
    $switch_opt->handle('key=val', $settings, $options, []);
    is($$switch_slot, {'key' => 'val', '@' => ['key']}, "Map set key=val");
};

subtest 'mixed old-style and new-style options' => sub {
    # Create an old-style options package
    {
        package Test::Bridge::OldPkg;
        use App::Yath::Options;

        option_group {prefix => 'display', category => 'Display'} => sub {
            option 'width' => (
                type        => 's',
                description => 'Terminal width',
                default     => 80,
            );
        };
    }

    my $options = App::Yath::Options->new();

    # Include old-style
    $options->include_from('Test::Bridge::OldPkg');

    # Include new-style
    $options->include_from('Test::Bridge::GetoptPkg');

    my @all = @{$options->all};
    ok(scalar @all >= 6, "Both old and new style options included");

    my $lookup = $options->lookup;
    ok($lookup->{'width'},     "Old-style 'width' option present");
    ok($lookup->{'job-count'}, "New-style 'job-count' option present");
    ok($lookup->{'color'},     "New-style 'color' option present");
};

subtest 'grab and process opts with adapted options' => sub {
    my $options = App::Yath::Options->new();
    $options->include(Test::Bridge::GetoptPkg->options);

    # Populate defaults
    for my $opt (@{$options->all}) {
        my $slot = $opt->option_slot($options->settings);
        my $val  = $opt->get_default($options->settings);
        $$slot //= $val;
    }

    # Set up args and process them
    my $args = ['--job-count', '4', '-vv', '--lib', '/my/lib', '--color', '--switch', 'foo=bar', '--no-color', 'remaining'];
    $options->{args} = $args;

    my @grabbed = $options->_grab_opts('all', 'test', passthrough => 1);
    ok(@grabbed > 0, "Grabbed some option actions");
    is($args, ['remaining'], "Non-option args remain");

    # Process the grabbed opts
    for my $opt_set (@grabbed) {
        my ($opt, $meth, @vals) = @$opt_set;
        $opt->$meth(@vals, $options->settings, $options, []);
    }

    my $s = $options->settings;
    is(${$s->define_prefix('runner')->vivify_field('job_count')}, 4, "job_count set to 4");
    is(${$s->define_prefix('runner')->vivify_field('color')}, 0, "color negated to 0");
    is(${$s->define_prefix('runner')->vivify_field('verbose')}, 2, "verbose counted to 2");
    is(${$s->define_prefix('runner')->vivify_field('lib')}, ['/my/lib'], "lib has one entry");
    is(${$s->define_prefix('runner')->vivify_field('switch')}, {'foo' => 'bar', '@' => ['foo']}, "switch map set");
};

done_testing;
