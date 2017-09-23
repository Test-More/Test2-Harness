use Test2::V0 -target => 'App::Yath::Command';
skip_all "Not done, come back!";

local $ENV{HARNESS_PERL_SWITCHES};

use Config qw/%Config/;

use File::Temp qw/tempdir/;

use ok $CLASS;

can_ok($CLASS, [qw/settings signal args plugins/], "Got public attributes");

can_ok(
    $CLASS, [
        qw{
            handle_list_args
            feeder
            cli_args
            internal_only
            has_jobs
            has_runner
            has_logger
            has_display
            show_bench
            always_keep_dir
            name
            summary
            description
            group
        }
    ],
    "Got public methods subclasses are expected to override"
);

{
    package App::Yath::Command::fake;
    use parent 'App::Yath::Command';

    sub cli_args {'xxx'}
}

my $TCLASS = 'App::Yath::Command::fake';

subtest for_override => sub {
    is([$CLASS->handle_list_args], [], "handle_list_args returns empty list");
    is([$CLASS->feeder],           [], "feeder returns empty list");
    is([$CLASS->cli_args],         [], "cli_args returns empty list");

    is($CLASS->internal_only,   0, "internal_only defaults to 0");
    is($CLASS->has_jobs,        0, "has_jobs defaults to 0");
    is($CLASS->has_runner,      0, "has_runner defaults to 0");
    is($CLASS->has_logger,      0, "has_logger defaults to 0");
    is($CLASS->has_display,     0, "has_display defaults to 0");
    is($CLASS->always_keep_dir, 0, "always_keep_dir defaults to 0");

    is($CLASS->show_bench,    1, "show_bench defaults to 1");

    is($CLASS->summary, "No Summary", "sane default summary");
    is($CLASS->description, "No Description", "sane default description");

    is($TCLASS->name, 'fake', "got name of command from class");
    is($TCLASS->new->name, 'fake', "got name of command from instance");

    is($CLASS->group, "ZZZZZZ", "Default group is near the end in an ASCII sort");
};

subtest my_opts => sub {
    my $control = mock $TCLASS;

    $control->override(has_jobs => sub { 1 });
    my $opts = $TCLASS->my_opts;
    for my $opt (@$opts) {
        next if $opt->{used_by}->{all};
        next if $opt->{used_by}->{jobs};
        fail("Got opt $opt->{spec}");
    }
    $control->reset('has_jobs');

    $control->override(has_runner => sub { 1 });
    $opts = $TCLASS->my_opts;
    for my $opt (@$opts) {
        next if $opt->{used_by}->{all};
        next if $opt->{used_by}->{runner};
        fail("Got opt $opt->{spec}");
    }
    $control->reset('has_runner');

    $control->override(has_logger => sub { 1 });
    $opts = $TCLASS->my_opts;
    for my $opt (@$opts) {
        next if $opt->{used_by}->{all};
        next if $opt->{used_by}->{logger};
        fail("Got opt $opt->{spec}");
    }
    $control->reset('has_logger');

    $control->override(has_display => sub { 1 });
    $opts = $TCLASS->my_opts;
    for my $opt (@$opts) {
        next if $opt->{used_by}->{all};
        next if $opt->{used_by}->{display};
        fail("Got opt $opt->{spec}");
    }
    $control->reset('has_display');

    $control->override(has_display => sub { 1 });
    $control->override(has_jobs    => sub { 1 });
    $control->override(has_logger  => sub { 1 });
    $control->override(has_runner  => sub { 1 });
    $opts = $TCLASS->my_opts;
    is(@$opts, (my @foo = $CLASS->options({})), "Got all opts");

    my $one = $TCLASS->new;
    ref_is($one->my_opts, $one->my_opts, "Command instance caches result");
};

subtest init => sub {
    my $control = mock $TCLASS;

    my $one = bless {}, $TCLASS;

    ok(lives { $one->init }, "can call init on empty instance");

    ref_ok($one->settings, 'HASH', 'Got a hash reference for settings');
    ref_ok($one->settings->{libs}, 'ARRAY', "libs setting was normalized");
    ok(!$one->settings->{dir}, "no dir");

    $control->override(has_runner  => sub { 1 });
    $one = $TCLASS->new();

    ok(my $dir = $one->settings->{dir}, "got a dir");
    my $garbage = File::Spec->canonpath($dir . '/garbage');

    open(my $fh, '>', $garbage) or die "Could not open file: $!";
    print $fh "garbage\n";
    close($fh);

    $one = undef;

    ok(-f $garbage, "Garbage file was left behind");

    like(
        dies { $one = $TCLASS->new(args => [-d => $dir]) },
        qr/^Work directory is not empty \(use -C to clear it\)/,
        "Cannot use a non-empty dir by default"
    );

    ok(lives { $one = $TCLASS->new(args => [-d => $dir, '-C']) }, "Can clear dir");
    ok(!-f $garbage, "garbage file was removed");


    $control->reset_all;

    local @INC = (File::Spec->canonpath('t/lib'), @INC);
    $one = $TCLASS->new(args => ['-pTest']);

    ok($INC{'App/Yath/Plugin/Test.pm'}, "Loaded test plugin") or return;

    is(
        App::Yath::Plugin::Test->GET_CALLS,
        {
            options   => [['App::Yath::Plugin::Test', exact_ref($one), exact_ref($one->settings)]],
            pre_init  => [['App::Yath::Plugin::Test', exact_ref($one), exact_ref($one->settings)]],
            post_init => [['App::Yath::Plugin::Test', exact_ref($one), exact_ref($one->settings)]],
        },
        "Called correct plugin methods",
    );
};

subtest normalize_settings => sub {
    my $control = mock $TCLASS;
    my $one = bless {}, $TCLASS;

    $control->override(
        my_opts => sub {
            return [
                {
                    spec  => 'foo',
                    field => 'foo',
                    default => 1,
                },

                {
                    spec   => 'bar',
                    field  => 'bar',
                    default => 1,
                    action => sub {
                        my $self = shift;
                        my ($settings, $field, $val, $opt) = @_;

                        $settings->{bar} = {self => $self, field => $field, val => $val, opt => $opt};
                    },
                },

                {
                    spec   => 'baz',
                    field  => 'bugaboo',
                    default => 1,
                    action => sub {
                        my $self = shift;
                        my ($settings, $field, $val, $opt) = @_;

                        $settings->{baz} = {self => $self, field => $field, val => $val, opt => $opt};
                    },
                },

                {
                    spec    => 'boo',
                    field   => 'boo',
                    default => sub {
                        my $self = shift;
                        my ($settings, $field) = @_;

                        return {self => $self, settings => $settings, field => $field};
                    },
                },

                {
                    spec      => 'bun=s',
                    field     => 'bun',
                    default => 'a value',
                    normalize => sub {
                        my $self = shift;
                        my ($settings, $field, $val) = @_;

                        return {self => $self, settings => $settings, field => $field, val => $val};
                    },
                }
            ];
        }
    );

    $one->{settings} = {};
    $one->settings->{libs} = ['xfoo', 'xbar'];
    $one->settings->{lib}  = 1;
    $one->settings->{blib} = 1;
    $one->settings->{tlib} = 1;

    {
        local $ENV{PERL5LIB} = 'xbaz' . $Config{path_sep} . 'xbat';
        my $fs_control = mock 'File::Spec' => (
            override => [
                rel2abs => sub { return "ABS $_[-1]" },
            ],
        );
        $one->normalize_settings();
    }

    is(
        $one->settings,
        hash {
            field lib  => 1;
            field blib => 1;
            field tlib => 1;
            field foo  => 1;

            field bar => {self => exact_ref($one), field => 'bar',     val => 1, opt => undef};
            field baz => {self => exact_ref($one), field => 'bugaboo', val => 1, opt => undef};
            field boo => {self => exact_ref($one), settings => exact_ref($one->settings), field => 'boo'};
            field bun => {self => exact_ref($one), settings => exact_ref($one->settings), field => 'bun', val => 'a value'};

            field env_vars => {HARNESS_IS_VERBOSE => 0, T2_HARNESS_IS_VERBOSE => 0};

            field libs => bag {
                item "ABS xfoo";
                item "ABS xbar";
                item "ABS xbaz";
                item "ABS xbat";
                item "ABS lib";
                item "ABS blib/lib";
                item "ABS blib/arch";
                item "ABS t/lib";
                end;
            };
            end;
        },
        "Got settings"
    );
};

subtest run => sub {
    my $control = mock $TCLASS;

    my $one = $TCLASS->new;

    $control->override('run_command' => sub { 321 });

    $control->override('pre_run' => sub { 123 });
    is($one->run, 123, "pre-run returned a value, did not call run_command");

    $control->override('pre_run' => sub { 0 });
    is($one->run, 0, "pre-run returned a 0 value, did not call run_command");

    $control->override('pre_run' => sub { undef });
    is($one->run, 321, "called run_command");
};

subtest pre_run => sub {
    my $control = mock $TCLASS;

    my $injected = 0;
    $control->override(inject_signal_handlers => sub { $injected++ });

    my @painted;
    $control->override(paint => sub { shift; push @painted => @_ });

    my $one = $TCLASS->new();

    $one->settings->{help} = 1;
    is($one->pre_run, 0, "returned 0 for help");
    is(\@painted, [$one->usage], "Painted usage info");
    ok(!$injected, "did not inject signal handlers");

    @painted = ();

    delete $one->settings->{help};
    $one->settings->{show_opts} = 1;
    $one->settings->{input} = 'foo' x 1000;
    require Test2::Harness::Util::JSON;
    my $json = Test2::Harness::Util::JSON::encode_pretty_json({ %{$one->settings}, input => '<TRUNCATED>' });
    is($one->pre_run, 0, "show opts returned 0");
    is(\@painted, [$json], "got options");
    ok(!$injected, "did not inject signal handlers");

    delete $one->settings->{show_opts};
    is($one->pre_run, undef, "pre_run did not return a defined value");
    is($injected, 1, "injected signal handlers");
};

subtest paint => sub {
    my $one = $TCLASS->new;

    my $out = '';
    open(my $fh, '>', \$out);
    my $old = select $fh;

    my $ok = eval {
        $one->settings->{quiet} = 1;
        $one->paint("foo\n");
        ok(!$out, "did not paint in quiet mode");

        $one->settings->{quiet} = 0;
        $one->paint("bar\n");
        is($out, "bar\n", "wrote outside of quiet mode");
    };
    my $err = $@;

    select $old;

    die $err unless $ok;
};

subtest make_run_from_settings => sub {
    my $one = bless(
        {
            settings => {
                run_id           => 123,
                job_count        => 3,
                switches         => ['-w'],
                libs             => ['foo', 'bar'],
                lib              => 1,
                blib             => 1,
                tlib             => 1,
                preload          => ['Scalar::Util'],
                load             => [],
                load_import      => [],
                pass             => ['--foo'],
                input            => "my input",
                search           => ['t', 't2'],
                unsafe_inc       => 1,
                env_vars         => {foo => 1, bar => 2},
                use_stream       => 1,
                use_fork         => 1,
                times            => 1,
                verbose          => 2,
                no_long          => 0,
                exclude_patterns => [qr/xxx/],
                exclude_files    => ['t/xxx.t'],
            },
            plugins => ['Foo::Bar'],
        },
        $TCLASS
    );

    my $fs_control = mock 'File::Spec' => (
        override => [
            rel2abs => sub { return "ABS $_[-1]" },
        ],
    );

    is(
        $one->make_run_from_settings(load => ['Foo::Bar']),
        object {
            call run_id           => 123;
            call job_count        => 3;
            call switches         => ['-w'];
            call libs             => ['foo', 'bar'];
            call lib              => 1;
            call blib             => 1;
            call tlib             => 1;
            call preload          => ['Scalar::Util'];
            call load             => ['Foo::Bar'];
            call load_import      => [];
            call args             => ['--foo'];
            call input            => "my input";
            call search           => ['t', 't2'];
            call unsafe_inc       => 1;
            call use_stream       => 1;
            call use_fork         => 1;
            call times            => 1;
            call verbose          => 2;
            call no_long          => 0;
            call plugins          => ['Foo::Bar'];
            call exclude_patterns => [qr/xxx/];
            call exclude_files    => {'ABS t/xxx.t' => 1};
            call env_vars         => hash {
                field foo => 1;
                field bar => 2;
                etc;
            };
        },
        "Got expected run"
    );
};

subtest section_order => sub {
    # Just test we get a sane list of strings, do not actually test order, that
    # can change for many reasons in the future.
    my @got = $CLASS->section_order;
    ok(@got > 1, "More than 1 item");
    ok((!grep { ref($_) } @got), "No references")
};

subtest options => sub {
    my $control = mock $TCLASS;

    $control->override(has_display => sub { 1 });
    $control->override(has_jobs    => sub { 1 });
    $control->override(has_logger  => sub { 1 });
    $control->override(has_runner  => sub { 1 });

    subtest show_opts => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{show_opts}, "not on by default");

        my $two = $TCLASS->new(args => ['--show-opts']);
        ok($two->settings->{show_opts}, "toggled on");
    };

    subtest help => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{help}, "not on by default");

        my $two = $TCLASS->new(args => ['--help']);
        ok($two->settings->{help}, "toggled on");

        my $three = $TCLASS->new(args => ['-h']);
        ok($three->settings->{help}, "toggled on (short)");
    };

    subtest include => sub {
        local $ENV{PERL5LIB};
        my $one = $TCLASS->new(args => ['--no-lib', '--no-blib', '--no-tlib']);
        ok(!$one->settings->{libs} || !@{$one->settings->{libs}}, "not on by default");

        my $two = $TCLASS->new(args => ['--no-lib', '--no-blib', '--no-tlib', '--include' => 'foo', '-Ibar', '-I' => 'baz', '--include=bat']);
        like(
            $two->settings->{libs},
            bag {
                item qr/foo$/;
                item qr/bar$/;
                item qr/baz$/;
                item qr/bat$/;
                end;
            },
            "Got added libs"
        );
    };

    subtest times => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{times}, "not on by default");

        my $two = $TCLASS->new(args => ['-T']);
        ok($two->settings->{times}, "toggled on");

        my $three = $TCLASS->new(args => ['--times']);
        ok($three->settings->{times}, "toggled on");

        my $four = $TCLASS->new(args => ['--times', '--no-times']);
        ok(!$four->settings->{times}, "toggled off");
    };

    subtest tlib => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{tlib}, "not on by default");

        my $two = $TCLASS->new(args => ['--tlib']);
        ok($two->settings->{tlib}, "toggled on");

        my $three = $TCLASS->new(args => ['--tlib', '--no-tlib']);
        ok(!$three->settings->{tlib}, "toggled off");
    };

    subtest lib => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{lib}, "on by default");

        my $two = $TCLASS->new(args => ['--no-lib']);
        ok(!$two->settings->{lib}, "toggled off");
    };

    subtest blib => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{blib}, "on by default");

        my $two = $TCLASS->new(args => ['--no-blib']);
        ok(!$two->settings->{blib}, "toggled off");
    };

    subtest input => sub {
        my $one = $TCLASS->new(args => []);
        ok(!defined($one->settings->{input}), "none by default");

        $one = $TCLASS->new(args => ['--input', 'foo bar baz']);
        is($one->settings->{input}, 'foo bar baz', "set the input string");
    };

    subtest 'keep-dir' => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{keep_dir}, "not on by default");

        my $two = $TCLASS->new(args => ['-k']);
        ok($two->settings->{keep_dir}, "toggled on");

        my $three = $TCLASS->new(args => ['--keep-dir']);
        ok($three->settings->{keep_dir}, "toggled on");

        my $four = $TCLASS->new(args => ['--keep-dir', '--no-keep-dir']);
        ok(!$four->settings->{keep_dir}, "toggled off");
    };

    subtest 'author-testing' => sub {
        my $one = $TCLASS->new(args => []);
        ok(!defined($one->settings->{env_vars}->{AUTHOR_TESTING}), "not on by default");

        my $two = $TCLASS->new(args => ['-A']);
        ok($two->settings->{env_vars}->{AUTHOR_TESTING}, "toggled on");

        my $three = $TCLASS->new(args => ['--author-testing']);
        ok($three->settings->{env_vars}->{AUTHOR_TESTING}, "toggled on");

        my $four = $TCLASS->new(args => ['--author-testing', '--lib', '--no-author-testing']);
        ok(!$four->settings->{env_vars}->{AUTHOR_TESTING}, "toggled off");
        ok(defined($four->settings->{env_vars}->{AUTHOR_TESTING}), "off, but defined");
    };

    subtest tap => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{use_stream}, "stream by default");

        my $two = $TCLASS->new(args => ['--tap']);
        ok(!$two->settings->{use_stream}, "use tap");

        my $three = $TCLASS->new(args => ['--TAP']);
        ok(!$three->settings->{use_stream}, "use TAP");
    };

    subtest use_stream => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{use_stream}, "stream by default");

        my $two = $TCLASS->new(args => ['--no-stream']);
        ok(!$two->settings->{use_stream}, "use tap");
    };

    subtest fork => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{use_fork}, "fork by default");

        my $two = $TCLASS->new(args => ['--no-fork']);
        ok(!$two->settings->{use_fork}, "no fork");
    };

    # Use is() for these to verify the normalization to 1 and 0
    subtest 'unsafe-inc' => sub {
        subtest undef_var => sub {
            local $ENV{PERL_USE_UNSAFE_INC};

            my $one = $TCLASS->new(args => []);
            is($one->settings->{unsafe_inc}, 1, "unsafe-inc by default");

            my $two = $TCLASS->new(args => ['--no-unsafe-inc']);
            is($two->settings->{unsafe_inc}, 0, "no unsafe-inc");
        };

        subtest true_var => sub {
            local $ENV{PERL_USE_UNSAFE_INC} = 'YES';

            my $one = $TCLASS->new(args => []);
            is($one->settings->{unsafe_inc}, 1, "unsafe-inc");

            my $two = $TCLASS->new(args => ['--no-unsafe-inc']);
            is($two->settings->{unsafe_inc}, 0, "no unsafe-inc");
        };

        subtest false_var => sub {
            local $ENV{PERL_USE_UNSAFE_INC} = '';

            my $one = $TCLASS->new(args => []);
            is($one->settings->{unsafe_inc}, 0, "no unsafe-inc");

            my $two = $TCLASS->new(args => ['--no-unsafe-inc']);
            is($two->settings->{unsafe_inc}, 0, "no unsafe-inc");
        };
    };

    subtest env_vars => sub {
        my $one = $TCLASS->new(args => ['-E', 'FOO=foo', '-EBAR=bar', '--env-var', 'BAZ=baz']);
        is(
            $one->settings->{env_vars},
            hash {
                field FOO => 'foo';
                field BAR => 'bar';
                field BAZ => 'baz';
                etc;
            },
            "Set env vars"
        );
    };

    subtest switch => sub {
        my $one = $TCLASS->new(args => [qw/-S -w -S-t --switch -e=foo=bar/]);
        is(
            $one->settings->{switches},
            [qw/-w -t -e foo=bar/],
            "Set switches"
        );
    };

    subtest clear => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{clear_dir}, "not on by default");

        my $two = $TCLASS->new(args => ['-C']);
        ok($two->settings->{clear_dir}, "toggled on");

        my $three = $TCLASS->new(args => ['--clear']);
        ok($three->settings->{clear_dir}, "toggled on");
    };

    subtest shm => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{use_shm}, "on by default");

        my $two = $TCLASS->new(args => ['--no-shm']);
        ok(!$two->settings->{use_shm}, "toggled off");
    };

    subtest tmpdir => sub {
        if (grep { -d $_ } map { File::Spec->canonpath($_) } '/dev/shm', '/run/shm') {
            my $one = $TCLASS->new(args => []);
            is($one->settings->{tmp_dir}, match qr{^/(run|dev)/shm/?$}, "temp dir in shm");
        }

        my $dir = tempdir(CLEANUP => 1, TMP => 1);

        local $ENV{TMPDIR} = $dir;
        my $two = $TCLASS->new(args => ['--no-shm']);
        is($two->settings->{tmp_dir}, $dir, "temp dir in set by TMPDIR");

        local $ENV{TEMPDIR} = delete $ENV{TMPDIR};
        my $three = $TCLASS->new(args => ['--no-shm']);
        is($three->settings->{tmp_dir}, $dir, "temp dir in set by TEMPDIR");

        delete $ENV{TEMPDIR};
        my $four = $TCLASS->new(args => ['--no-shm']);
        is($four->settings->{tmp_dir}, File::Spec->tmpdir, "system temp dir");
    };

    subtest workdir => sub {
        my $dir = tempdir(CLEANUP => 1, TMP => 1);

        local $ENV{T2_WORKDIR} = $dir;
        my $one = $TCLASS->new(args => []);
        is($one->settings->{dir}, $dir, "Set via env var");

        delete $ENV{T2_WORKDIR};

        delete $ENV{TMPDIR};
        delete $ENV{TEMPDIR};
        my $two = $TCLASS->new(args => []);
        like($two->settings->{dir}, qr{yath-test-$$}, "Generated a directory");
    };

    subtest no_long => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{no_long}, "off by default");

        my $two = $TCLASS->new(args => ['--no-long']);
        ok($two->settings->{no_long}, "toggled on");
    };

    subtest exclude_files => sub {
        my $one = $TCLASS->new(args => []);
        is($one->settings->{exclude_files}, [], "default is an empty array");

        my $two = $TCLASS->new(args => ['-x', 'xxx.t']);
        is($two->settings->{exclude_files}, ['xxx.t'], "excluded a file");

        my $three = $TCLASS->new(args => ['--exclude-file', 'xxx.t']);
        is($three->settings->{exclude_files}, ['xxx.t'], "excluded a file");
    };

    subtest exclude_pattern => sub {
        my $one = $TCLASS->new(args => []);
        is($one->settings->{exclude_patterns}, [], "default is an empty array");

        my $two = $TCLASS->new(args => ['-X', qr/xyz/]);
        is($two->settings->{exclude_patterns}, [qr/xyz/], "excluded a pattern");

        my $three = $TCLASS->new(args => ['--exclude-pattern', qr/xyz/]);
        is($three->settings->{exclude_patterns}, [qr/xyz/], "excluded a pattern");
    };

    subtest run_id => sub {
        my $one = $TCLASS->new(args => []);
        ok($one->settings->{run_id}, "default is a timestamp");

        my $two = $TCLASS->new(args => ['--id', 'foo']);
        is($two->settings->{run_id}, 'foo', "set id to foo");

        my $three = $TCLASS->new(args => ['--run-id', 'foo']);
        is($three->settings->{run_id}, 'foo', "set id to foo");
    };

    subtest job_count => sub {
        my $one = $TCLASS->new(args => []);
        is($one->settings->{job_count}, 1, "default is 1");

        my $two = $TCLASS->new(args => ['-j3']);
        is($two->settings->{job_count}, 3, "set to 3");

        my $three = $TCLASS->new(args => ['--jobs', '3']);
        is($three->settings->{job_count}, 3, "set to 3");

        my $four = $TCLASS->new(args => ['--job-count', '3']);
        is($four->settings->{job_count}, 3, "set to 3");
    };

    subtest preload => sub {
        my $one = $TCLASS->new(args => []);
        is($one->settings->{preload}, undef, "No preloads");

        my $two = $TCLASS->new(args => ['-PScalar::Util', '--preload', 'List::Util']);
        is($two->settings->{preload}, ['Scalar::Util', 'List::Util'], "Added preload");

        my $three = $TCLASS->new(args => ['-PScalar::Util', '--preload', 'List::Util', '--no-preload', '-PData::Dumper']);
        is($three->settings->{preload}, ['Data::Dumper'], "Added preload after canceling previous ones");
    };

    subtest plugin => sub {
        my $one = $TCLASS->new(args => []);
        is($one->plugins, [], "No plugins");

        @INC = ('t/lib', @INC);

        my $two = $TCLASS->new(args => ['-pTest', '--plugin', 'TestNew']);
        is($two->plugins, ['App::Yath::Plugin::Test', object { prop blessed => 'App::Yath::Plugin::TestNew' }], "Added plugin");

        my $three = $TCLASS->new(args => ['-pFail', '--plugin', 'Fail', '--no-plugins', '-pTest']);
        is($three->plugins, ['App::Yath::Plugin::Test'], "Added plugin after canceling previous ones");
    };

    subtest dummy => sub {
        local $ENV{T2_HARNESS_DUMMY} = 0;
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{dummy}, "not dummy by default");

        $ENV{T2_HARNESS_DUMMY} = 1;
        my $two = $TCLASS->new(args => []);
        ok($two->settings->{dummy}, "dummy by default with env var");

        $ENV{T2_HARNESS_DUMMY} = 0;
        my $three = $TCLASS->new(args => ['-D']);
        ok($three->settings->{dummy}, "dummy turned on");

        my $four = $TCLASS->new(args => ['--dummy']);
        ok($four->settings->{dummy}, "dummy turned on");
    };

    subtest load => sub {
        my $one = $TCLASS->new(args => []);
        ok(!$one->settings->{load}, "no loads by default");
        
    };
};

done_testing;

__END__

        {
            spec    => 'm|load|load-module=s@',
            field   => 'load',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-m Module', '--load Module', '--load-module Mod'],
            summary => ['Load a module in each test (after fork)', 'this option may be given multiple times'],
        },

        {
            spec    => 'M|loadim|load-import=s@',
            field   => 'load_import',
            used_by => {runner => 1, jobs => 1},
            section => 'Harness Options',
            usage   => ['-M Module', '--loadim Module', '--load-import Mod'],
            summary => ['Load and import module in each test (after fork)', 'this option may be given multiple times'],
        },


        {
            spec      => 'et|event_timeout=i',
            field     => 'event_timeout',
            used_by   => {jobs => 1},
            section   => 'Harness Options',
            usage     => ['--et SECONDS', '--event_timeout #'],
            summary   => ['Kill test if no events received in timeout period', '(Default: 60 seconds)'],
            long_desc => 'This is used to prevent the harness for waiting forever for a hung test. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 60,
        },

        {
            spec      => 'pet|post-exit-timeout=i',
            field     => 'post_exit_timeout',
            used_by   => {jobs => 1},
            section   => 'Harness Options',
            usage     => ['--pet SECONDS', '--post-exit-timeout #'],
            summary   => ['Stop waiting post-exit after the timeout period', '(Default: 15 seconds)'],
            long_desc => 'Some tests fork and allow the parent to exit before writing all their output. If Test2::Harness detects an incomplete plan after the test exists it will monitor for more events until the timeout period. Add the "# HARNESS-NO-TIMEOUT" comment to the top of a test file to disable timeouts on a per-test basis.',
            default   => 15,
        },

        {
            spec    => 'F|log-file=s',
            field   => 'log_file',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-F file.jsonl', '--log-file FILE'],
            summary => ['Specify the name of the log file', 'This option implies -L', "(Default: event_log-RUN_ID.jsonl)"],
            normalize => sub { File::Spec->rel2abs($_[3]) },
            default   => sub {
                my ($self, $settings, $field) = @_;

                return unless $settings->{bzip2_log} || $settings->{gzip_log} || $settings->{log};

                mkdir('test-logs') or die "Could not create dir 'test-logs': $!"
                    unless -d 'test-logs';

                return File::Spec->catfile('test-logs', strftime("%Y-%m-%d~%H:%M:%S", localtime()). "~$settings->{run_id}~$$.jsonl");
            },
        },

        {
            spec    => 'B|bz2|bzip2-log',
            field   => 'bzip2_log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-B  --bz2', '--bzip2-log'],
            summary => ['Use bzip2 compression when writing the log', 'This option implies -L', '.bz2 prefix is added to log file name for you'],
        },

        {
            spec    => 'G|gz|gzip-log',
            field   => 'gzip_log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-G  --gz', '--gzip-log'],
            summary => ['Use gzip compression when writing the log', 'This option implies -L', '.gz prefix is added to log file name for you'],
        },

        {
            spec    => 'L|log',
            field   => 'log',
            used_by => {logger => 1},
            section => 'Logging Options',
            usage   => ['-L', '--log'],
            summary => ['Turn on logging'],
            default => sub {
                my ($self, $settings) = @_;
                return 1 if $settings->{log_file};
                return 1 if $settings->{bzip2_log};
                return 1 if $settings->{gzip_log};
                return 0;
            },
        },

        {
            spec    => 'color!',
            field   => 'color',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--color', '--no-color'],
            summary => ["Turn color on (Default: on)", "Turn color off"],
            default => 1,
        },

        {
            spec    => 'q|quiet!',
            field   => 'quiet',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-q', '--quiet'],
            summary => ["Be very quiet"],
            default => 0,
        },

        {
            spec    => 'r|renderer=s',
            field   => 'renderer',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-r +Module', '-r Postfix', '--renderer ...'],
            summary   => ['Specify an alternate renderer', '(Default: "Formatter")'],
            long_desc => 'Use "+" to give a fully qualified module name. Without "+" "Test2::Harness::Renderer::" will be prepended to your argument.',
            default   => '+Test2::Harness::Renderer::Formatter',
        },

        {
            spec    => 'v|verbose+',
            field   => 'verbose',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['-v   -vv', '--verbose'],
            summary => ['Turn on verbose mode.', 'Specify multiple times to be more verbose.'],
            default => 0,
        },

        {
            spec      => 'formatter=s',
            field     => 'formatter',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['--formatter Mod', '--formatter +Mod'],
            summary   => ['Specify the formatter to use', '(Default: "Test2")'],
            long_desc => 'Only useful when the renderer is set to "Formatter". This specified the Test2::Formatter::XXX that will be used to render the test output.',
            default   => '+Test2::Formatter::Test2',
        },

        {
            spec      => 'show-job-end!',
            field     => 'show_job_end',
            used_by   => {display => 1},
            section   => 'Display Options',
            usage     => ['--show-job-end', '--no-show-job-end'],
            summary   => ['Show output when a job ends', '(Default: on)'],
            long_desc => 'This is only used when the renderer is set to "Formatter"',
            default   => 1,
        },

        {
            spec    => 'show-job-info!',
            field   => 'show_job_info',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-job-info', '--no-show-job-info'],
            summary => ['Show the job configuration when a job starts', '(Default: off, unless -vv)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose} > 1;
                return 0;
            },
        },

        {
            spec    => 'show-job-launch!',
            field   => 'show_job_launch',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-job-launch', '--no-show-job-launch'],
            summary => ["Show output for the start of a job", "(Default: off unless -v)"],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose};
                return 0;
            },
        },

        {
            spec    => 'show-run-info!',
            field   => 'show_run_info',
            used_by => {display => 1},
            section => 'Display Options',
            usage   => ['--show-run-info', '--no-show-run-info'],
            summary => ['Show the run configuration when a run starts', '(Default: off, unless -vv)'],
            default => sub {
                my ($self, $settings, $field) = @_;
                return 1 if $settings->{verbose} > 1;
                return 0;
            },
        },
    );
}
# }}}

sub pre_parse_args {
    my $self = shift;
    my ($args) = @_;

    my (@opts, @list, @pass, @plugins);

    my $last_mark = '';
    for my $arg (@{$self->args}) {
        if ($last_mark eq '::') {
            push @pass => $arg;
        }
        elsif ($last_mark eq '--') {
            if ($arg eq '::') {
                $last_mark = $arg;
                next;
            }
            push @list => $arg;
        }
        elsif ($last_mark eq '-p' || $last_mark eq '--plugin') {
            $last_mark = '';
            push @plugins => $arg;
        }
        else {
            if ($arg eq '--' || $arg eq '::') {
                $last_mark = $arg;
                next;
            }
            if ($arg eq '-p' || $arg eq '--plugin') {
                $last_mark = $arg;
                next;
            }
            if ($arg =~ m/^(?:-p=?|--plugin=)(.*)$/) {
                push @plugins => $1;
                next;
            }
            if ($arg eq '--no-plugins') {
                # clear plugins
                @plugins = ();
                next;
            }
            push @opts => $arg;
        }
    }

    return (\@opts, \@list, \@pass, \@plugins);
}

sub parse_args {
    my $self = shift;
    my ($args) = @_;

    my ($opts, $list, $pass, $plugins) = $self->pre_parse_args($args);

    my $settings = $self->{+SETTINGS} ||= {};
    $settings->{pass} = $pass;

    my @plugin_options;
    for my $plugin (@$plugins) {
        local $@;
        $plugin = fqmod('App::Yath::Plugin', $plugin);
        my $file = pkg_to_file($plugin);
        eval { require $file; 1 } or die "Could not load plugin '$plugin': $@";

        push @plugin_options => $plugin->options($self, $settings);
        $plugin->pre_init($self, $settings);
    }

    $self->{+PLUGINS} = $plugins;

    my @opt_map = map {
        my $spec  = $_->{spec};
        my $action = $_->{action};
        my $field = $_->{field};
        if ($action) {
            my ($opt, $arg) = @_;
            my $inner = $action;
            $action = sub { $self->$inner($settings, $field, $arg, $opt) }
        }
        elsif ($field) {
            $action = \($settings->{$field});
        }

        ($spec => $action)
    } @{$self->my_opts(plugin_options => \@plugin_options)};

    Getopt::Long::Configure("bundling");
    my $args_ok = GetOptionsFromArray($opts => @opt_map)
        or die "Could not parse the command line options given.\n";

    return [grep { defined($_) && length($_) } @$list, @$opts];
}

sub usage_opt_order {
    my $self = shift;

    my $idx = 1;
    my %lookup = map {($_ => $idx++)} $self->section_order;

    #<<< no-tidy
    return sort {
          ($lookup{$a->{section}} || 99) <=> ($lookup{$b->{section}} || 99)  # Sort by section first
            or ($a->{long_desc} ? 2 : 1) <=> ($b->{long_desc} ? 2 : 1)       # Things with long desc go to bottom
            or      lc($a->{usage}->[0]) cmp lc($b->{usage}->[0])            # Alphabetical by first usage example
            or       ($a->{field} || '') cmp ($b->{field} || '')             # By field if present
    } grep { $_->{section} } @{$self->my_opts};
    #>>>
}

sub usage_pod {
    my $in = shift;
    my $name = $in->name;

    my @list = $in->usage_opt_order;

    my $out = "\n=head1 COMMAND LINE USAGE\n";

    my @cli_args = $in->cli_args;
    @cli_args = ('') unless @cli_args;

    for my $args (@cli_args) {
        $out .= "\n    \$ yath $name [options]";
        $out .= " $args" if $args;
        $out .= "\n";
    }

    my $section = '';
    for my $opt (@list) {
        my $sec = $opt->{section};
        if ($sec ne $section) {
            $out .= "\n=back\n" if $section;
            $section = $sec;
            $out .= "\n=head2 $section\n";
            $out .= "\n=over 4\n";
        }

        for my $way (@{$opt->{usage}}) {
            my @parts = split /\s+-/, $way;
            my $count = 0;
            for my $part (@parts) {
                $part = "-$part" if $count++;
                $out .= "\n=item $part\n"
            }
        }

        for my $sum (@{$opt->{summary}}) {
            $out .= "\n$sum\n";
        }

        if (my $desc = $opt->{long_desc}) {
            chomp($desc);
            $out .= "\n$desc\n";
        }
    }

    $out .= "\n=back\n";

    return $out;
}

sub usage {
    my $self = shift;
    my $name = $self->name;

    my @list = $self->usage_opt_order;

    # Get the longest 'usage' item's length
    my $ul = max(map { length($_) } map { @{$_->{usage}} } @list);

    my $section = '';
    my @options;
    for my $opt (@list) {
        my $sec = $opt->{section};
        if ($sec ne $section) {
            $section = $sec;
            push @options => "  $section:";
        }

        my @set;
        for (my $i = 0; 1; $i++) {
            my $usage = $opt->{usage}->[$i]   || '';
            my $summ  = $opt->{summary}->[$i] || '';
            last unless length($usage) || length($summ);

            my $line = sprintf("    %-${ul}s    %s", $usage, $summ);

            if (length($line) > 80) {
                my @words = grep { $_ } split /(\s+)/, $line;
                my @lines;
                while (@words) {
                    my $prefix = @lines ? (' ' x ($ul + 8)) : '';
                    my $length = length($prefix);

                    shift @words while @lines && @words && $words[0] =~ m/^\s+$/;
                    last unless @words;

                    my @line;
                    while (@words && (!@line || 80 >= $length + length($words[0]))) {
                        $length += length($words[0]);
                        push @line => shift @words;
                    }
                    push @lines => $prefix . join '' => @line;
                }

                push @set => join "\n" => @lines;
            }
            else {
                push @set => $line;
            }
        }
        push @options => join "\n" => @set;

        if (my $desc = $opt->{long_desc}) {
            chomp($desc);

            my @words = grep { $_ } split /(\s+)/, $desc;
            my @lines;
            my $size = 0;
            while (@words && $size != @words) {
                $size = @words;
                my $prefix = '        ';
                my $length = 8;

                shift @words while @lines && @words && $words[0] =~ m/^\s+$/;
                last unless @words;

                my @line;
                while (@words && (!@line || 80 >= $length + length($words[0]))) {
                    $length += length($words[0]);
                    push @line => shift @words;
                }
                push @lines => $prefix . join '' => @line;
            }

            push @options => join("\n" => @lines) . "\n";
        }
    }

    chomp(my @cli_args    = $self->cli_args);
    chomp(my $description = $self->description);

    my $head_common = "$0 $name [options]";
    my $header = join(
        "\n",
        "Usage: $head_common " . shift(@cli_args),
        map { "       $head_common $_" } @cli_args
    );

    my $options = join "\n\n" => @options;

    my $usage = <<"    EOT";

$header

$description

OPTIONS:

$options

    EOT

    return $usage;
}

sub loggers {
    my $self     = shift;
    my $settings = $self->{+SETTINGS};
    my $loggers  = [];

    return $loggers unless $settings->{log};

    my $file = $settings->{log_file};

    my $log_fh;
    if ($settings->{bzip2_log}) {
        $file = $settings->{log_file} = "$file.bz2";
        require IO::Compress::Bzip2;
        $log_fh = IO::Compress::Bzip2->new($file) or die "IO::Compress::Bzip2 failed: $IO::Compress::Bzip2::Bzip2Error\n";
    }
    elsif ($settings->{gzip_log}) {
        $file = $settings->{log_file} = "$file.gz";
        require IO::Compress::Gzip;
        $log_fh = IO::Compress::Gzip->new($file) or die "IO::Compress::Bzip2 failed: $IO::Compress::Gzip::GzipError\n";
    }
    else {
        $log_fh = open_file($file, '>');
    }

    require Test2::Harness::Logger::JSONL;
    push @$loggers => Test2::Harness::Logger::JSONL->new(fh => $log_fh);

    return $loggers;
}

sub renderers {
    my $self      = shift;
    my $settings  = $self->{+SETTINGS};
    my $renderers = [];

    return $renderers if $settings->{quiet};

    my $r = $settings->{renderer} or return $renderers;

    if ($r eq '+Test2::Harness::Renderer::Formatter' || $r eq 'Formatter') {
        require Test2::Harness::Renderer::Formatter;

        my $formatter = $settings->{formatter} or die "No formatter specified.\n";
        my $f_class;

        if ($formatter eq '+Test2::Formatter::Test2' || $formatter eq 'Test2') {
            require Test2::Formatter::Test2;
            $f_class = 'Test2::Formatter::Test2';
        }
        else {
            $f_class = fqmod('Test2::Formatter', $formatter);
            my $file = pkg_to_file($f_class);
            require $file;
        }

        push @$renderers => Test2::Harness::Renderer::Formatter->new(
            show_job_info   => $settings->{show_job_info},
            show_run_info   => $settings->{show_run_info},
            show_job_launch => $settings->{show_job_launch},
            show_job_end    => $settings->{show_job_end},
            formatter       => $f_class->new(verbose => $settings->{verbose}, color => $settings->{color}),
        );
    }
    elsif ($settings->{formatter}) {
        die "The formatter option is only available when the 'Formatter' renderer is in use.\n";
    }
    else {
        my $r_class = fqmod('Test2::Harness::Renderer', $r);
        require $r_class;
        push @$renderers => $r_class->new(verbose => $settings->{verbose}, color => $settings->{color});
    }

    return $renderers;
}

sub inject_signal_handlers {
    my $self = shift;

    my $handle_sig = sub {
        my ($sig) = @_;

        $self->{+SIGNAL} = $sig;

        die "Cought SIG$sig, Attempting to shut down cleanly...\n";
    };

    $SIG{INT}  = sub { $handle_sig->('INT') };
    $SIG{TERM} = sub { $handle_sig->('TERM') };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Command - Base class for yath commands

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
