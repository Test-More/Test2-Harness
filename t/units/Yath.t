use Test2::Bundle::Extended -target => 'App::Yath';

can_ok($CLASS, qw/args harness files exclude renderers help/);

subtest expand_files => sub {
    my $one = $CLASS->new;

    my $got = $one->expand_files;
    ok(@$got, "found test files");
    ok(!(grep { $_ !~ m{^t/} } @$got), "All files are in t/");

    my ($file) = @$got;

    is(
        $one->expand_files('t'),
        $got,
        "Specifying nothing is the same as saying 't'"
    );

    is(
        $one->expand_files($file),
        [$file],
        "A single file does not expand"
    );

    $file = shift @$got;
    $one->set_exclude([quotemeta($file)]);
    is(
        $one->expand_files('t'),
        $got,
        "Excluded the specified file ($file)"
    );
};

subtest args_and_init => sub {
    my $ignore = '';
    like(
        do { local *STDOUT; open(STDOUT, '>', \$ignore); $CLASS->new( args => [] ) },

        object {
            call harness => object {
                prop blessed => 'Test2::Harness';
                call listeners => [ T(), DNE ];
                call env_vars => hash  {end};
                call libs     => array {end};
                call switches => array {end};
                call parser_class => 'Test2::Harness::Parser';
                call runner       => object { prop blessed => 'Test2::Harness::Runner' };
                call jobs         => 1;
            };
            call renderers => array {
                item object {
                    prop blessed => 'Test2::Harness::Renderer::EventStream';
                    call color => 0;
                    call parallel => 1;
                    call verbose => 0;
                };
                end;
            };
            call exclude => array {end};
            call files => array {};
        },

        "Got expected default structure"
    );

    like(
        $CLASS->new(
            args => [qw{
                -I lib -Ifoo --include=baz --include bat -It/lib
                -R TestRenderer1 --renderer=TestRenderer2 --renderer +test_renderer
                -Ltest_preload1 --preload=test_preload2
                -c2
                -j5
                -m
                -q
                -v
                -xfoo --exclude=bar
                --parser +test_parser
                --runner +test_runner
            }, __FILE__],
        ),

        object {
            call harness => object {
                prop blessed => 'Test2::Harness';
                call listeners => [ T(), T(), T(), DNE ];
                call env_vars => hash  {end};
                call libs     => [qw{lib foo baz bat t/lib}];
                call switches => array {end};
                call parser_class => 'test_parser';
                call runner       => object { prop blessed => 'test_runner' };
                call jobs         => 5;
            };
            call renderers => array {
                item object {
                    prop blessed => 'Test2::Harness::Renderer::TestRenderer1';
                    call color => 2;
                    call parallel => 5;
                    call verbose => 1;
                };
                item object {
                    prop blessed => 'Test2::Harness::Renderer::TestRenderer2';
                    call color => 2;
                    call parallel => 5;
                    call verbose => 1;
                };
                item object {
                    prop blessed => 'test_renderer';
                    call color => 2;
                    call parallel => 5;
                    call verbose => 1;
                };
                end;
            };
            call exclude => [qw/foo bar/];
            call files => array {item __FILE__; end};
        },

        "Got expected structure"
    );

    like(
        do { local *STDOUT; open(STDOUT, '>', \$ignore); $CLASS->new( args => [qw/-S-foo --switch --bar=baz/] ) },

        object {
            call harness => object {
                prop blessed => 'Test2::Harness';
                call listeners => [ T(), DNE ];
                call env_vars => hash  {end};
                call libs     => array {end};
                call switches => [qw/-foo --bar baz/, DNE];
                call parser_class => 'Test2::Harness::Parser';
                call runner       => object { prop blessed => 'Test2::Harness::Runner' };
                call jobs         => 1;
            };
            call renderers => array {
                item object {
                    prop blessed => 'Test2::Harness::Renderer::EventStream';
                    call color => 0;
                    call parallel => 1;
                    call verbose => 0;
                };
                end;
            };
            call exclude => array {end};
            call files => array {};
        },

        "Got expected default structure + switches"
    );

    is(
        dies { $CLASS->new( args => [qw/-S-foo -Lbar/] ) },
        "You cannot combine preload (-L) with switches (-S).\n",
        "Cannot combine preload and switches"
    );
};

subtest run => sub {
    my $one = $CLASS->new;
    my @got;

    $one->set_harness(mock obj => (add => [run => sub {[ mock {passed => 1} ]}]));
    $one->set_renderers([mock obj => (add => [summary => sub { push @got => pop }])]);

    ok(!$one->run, "no failures");
    like(
        \@got,
        [[{passed => 1}]],
        "Got the result in the renderer"
    );
};

subtest libs => sub {
	like(
		$CLASS->new(args => [qw/-l -b -I foo/]),
		object {
			call harness => object {
				call libs => [qw{lib blib/lib blib/arch foo}];
			};
		},
		"Got expected libs with -l, -b, and -I (-l and -b before -I)"
	);
};

done_testing;
