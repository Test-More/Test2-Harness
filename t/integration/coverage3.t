use Test2::V0;
use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Require::Module 'Test2::Plugin::Cover' => '0.000022';

use App::Yath::Tester qw/yath/;

use File::Temp qw/tempfile/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};
$dir =~ s/\d+$//;

my ($fh, $logfile) = tempfile("yathlog-$$-XXXXXXXX", TMPDIR => 1, UNLINK => 1, SUFFIX => '.jsonl.bz2');
close($fh);

yath(
    command => 'test',
    args    => ["-I$dir/lib", $dir, '--ext=tx', '-v', '-B', '-F' => $logfile, '--cover-files', '--cover-agg' => 'ByRun'],
    exit    => 0,
);

yath(
    command => 'test',
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', "--cover-from=$logfile", '--plugin' => '+Plugin', '--changed-only', '-v'],
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
