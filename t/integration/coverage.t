use Test2::V0;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;

use App::Yath::Tester qw/yath/;

use File::Temp qw/tempfile/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my ($fh, $cfile) = tempfile(SUFFIX => '.json');
close($fh);

yath(
    command => 'test',
    args    => ["-I$dir/lib", $dir, '--ext=tx', "--write-coverage=$cfile", '-v'],
    exit    => 0,
);

open($fh, '<', $cfile);
my $json = join '' => <$fh>;
my $coverage = decode_json($json);

is(
    $coverage,
    {
        'testmeta' => {
            't/integration/coverage/a.tx'    => {'manager' => 'Manager', 'type' => 'split'},
            't/integration/coverage/b.tx'    => {'type'    => 'flat'},
            't/integration/coverage/c.tx'    => {'manager' => 'Manager', 'type' => 'split'},
            't/integration/coverage/once.tx' => {'type'    => 'flat'},
            't/integration/coverage/open.tx' => {'type'    => 'flat'},
            't/integration/coverage/x.tx'    => {'type'    => 'flat'},
        },
        'files' => {
            'Ax.pm' => {
                '*' => {
                    't/integration/coverage/a.tx' => ['*'],
                    't/integration/coverage/c.tx' => [{'subtest' => 'a'}],
                },
                'a' => {
                    't/integration/coverage/a.tx' => bag {
                        item {'subtest' => 'c'};
                        item {'subtest' => 'b'};
                        item {'subtest' => 'a'};
                        end;
                    },
                    't/integration/coverage/c.tx' => bag {
                        item {'subtest' => 'c'};
                        item {'subtest' => 'a'};
                        end;
                    },
                },
                'aa' => {'t/integration/coverage/a.tx' => [{'subtest' => 'a'}]},
            },
            'Bx.pm' => {
                '*' => {
                    't/integration/coverage/a.tx' => ['*'],
                    't/integration/coverage/b.tx' => ['*'],
                    't/integration/coverage/x.tx' => ['*'],
                },
                '<>' => {'t/integration/coverage/open.tx' => ['*']},
                'b'  => {
                    't/integration/coverage/a.tx' => bag {
                        item {'subtest' => 'c'};
                        item {'subtest' => 'b'};
                        end;
                    },
                    't/integration/coverage/b.tx' => ['*'],
                },
            },
            'Cx.pm' => {
                '*' => {
                    't/integration/coverage/a.tx' => ['*'],
                    't/integration/coverage/c.tx' => [{'subtest' => 'c'}],
                },
                'c' => {
                    't/integration/coverage/a.tx' => [
                        '*',
                        {'subtest' => 'c'},
                    ],
                    't/integration/coverage/c.tx' => [{'subtest' => 'c'}]
                },
            },
        },
    },
    "Got predicted coverage data",
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Ax'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                't/integration/coverage/a.tx' => {env => {COVER_TEST_SUBTESTS => 'a, b, c'}, stdin => "a\nb\nc\n", argv => ['a', 'b', 'c']},
                't/integration/coverage/c.tx' => {env => {COVER_TEST_SUBTESTS => 'a, c'},    stdin => "a\nc\n",    argv => ['a', 'c']},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Bx'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                # No manager, so run entire tests
                't/integration/coverage/b.tx'    => {argv => [], env => {}, stdin => ''},
                't/integration/coverage/x.tx'    => {argv => [], env => {}, stdin => ''},
                't/integration/coverage/open.tx' => {argv => [], env => {}, stdin => ''},

                # Managed, so we have custom input
                't/integration/coverage/a.tx' => {'argv' => ['b', 'c'], 'env' => {'COVER_TEST_SUBTESTS' => 'b, c'}, 'stdin' => "b\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Cx'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["c"], "env" => {"COVER_TEST_SUBTESTS" => "c"}, "stdin" => "c\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["c"], "env" => {"COVER_TEST_SUBTESTS" => "c"}, "stdin" => "c\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Bxb'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/b.tx"    => {"argv" => [], "env" => {}, "stdin" => ""},
                "t/integration/coverage/open.tx" => {"argv" => [], "env" => {}, "stdin" => ""},
                "t/integration/coverage/x.tx"    => {"argv" => [], "env" => {}, "stdin" => ""},

                "t/integration/coverage/a.tx" => {"argv" => ["b", "c"], "env" => {"COVER_TEST_SUBTESTS" => "b, c"}, "stdin" => "b\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Cxc'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["c"], "env" => {"COVER_TEST_SUBTESTS" => "c"}, "stdin" => "c\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["c"], "env" => {"COVER_TEST_SUBTESTS" => "c"}, "stdin" => "c\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Ax*'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["a", "b", "c"], "env" => {"COVER_TEST_SUBTESTS" => "a, b, c"}, "stdin" => "a\nb\nc\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["a", "c"],      "env" => {"COVER_TEST_SUBTESTS" => "a, c"},    "stdin" => "a\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Axa'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["a", "b", "c"], "env" => {"COVER_TEST_SUBTESTS" => "a, b, c"}, "stdin" => "a\nb\nc\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["a", "c"],      "env" => {"COVER_TEST_SUBTESTS" => "a, c"},    "stdin" => "a\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Axaa'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["a"], "env" => {"COVER_TEST_SUBTESTS" => "a"}, "stdin" => "a\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["a"], "env" => {"COVER_TEST_SUBTESTS" => "a"}, "stdin" => "a\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'Axaaa'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["a", "b", "c"], "env" => {"COVER_TEST_SUBTESTS" => "a, b, c"}, "stdin" => "a\nb\nc\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["a", "c"],      "env" => {"COVER_TEST_SUBTESTS" => "a, c"},    "stdin" => "a\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--coverage-from=$cfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
    exit    => 0,
    env     => {TEST_CASE => 'AxCx'},
    test    => sub {
        my $out   = shift;
        my $input = +{$out->{output} =~ m/INPUT (\S+): (\{.+\})$/gm};
        $_ = decode_json($_) for values %$input;
        is(
            $input,
            {
                "t/integration/coverage/a.tx" => {"argv" => ["a", "b", "c"], "env" => {"COVER_TEST_SUBTESTS" => "a, b, c"}, "stdin" => "a\nb\nc\n"},
                "t/integration/coverage/c.tx" => {"argv" => ["a", "c"],      "env" => {"COVER_TEST_SUBTESTS" => "a, c"},    "stdin" => "a\nc\n"},
            },
            "Test got the correct input about what subtests to run",
        );
    },
);

done_testing;
