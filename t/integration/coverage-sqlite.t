use Test2::Plugin::IsolateTemp;
use Test2::V0;

use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::Module 'DateTime::Format::SQLite';

use Test2::Tools::QuickDB;

use Test2::Harness::Util::JSON qw/encode_json decode_json/;
use Test2::Require::Module 'Test2::Plugin::Cover' => '0.000022';

use App::Yath::Schema::Config;
use App::Yath::Server;

use App::Yath::Tester qw/yath/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};
$dir =~ s/\d+$//;
$dir =~ s{-sqlite}{}g;

skipall_unless_can_db(driver => 'SQLite');
my $config = App::Yath::Schema::Config->new(ephemeral => 'SQLite');
my $server = App::Yath::Server->new(schema_config => $config);
my $db = $server->start_ephemeral_db;
my $dsn = $db->connect_string('harness_ui');;

my @yath_args = (
    '--db-dsn'  => $dsn,
    '--project' => 'test',
    '--db-publisher' => 'root',
    '--publish-mode' => 'complete',
    '--renderer' => 'DB',
    '--publish-user' => 'root',
);

# Run twice so we have extra coverage data
for (1 .. 2) {
    yath(
        command => 'test',
        pre     => ['-D./lib'],
        exit    => 0,
        env     => {A_FAIL_ONCE => 1},
        args    => [
            "-D",
            "-I$dir/lib",
            $dir,
            '--ext=tx',
            '-v',
            @yath_args,
            '--cover-files',
            '--cover-metrics',
            '--retry' => 1,
        ],
        test => sub {
            my $out = shift;
            ok($out->{output} !~ m/YathUI-DB Renderer error/, "No database error");
            ok($out->{output} =~ m{RETRY.*t/integration/coverage/a\.tx}, "retried a.tx");
        },
    );
}

$ENV{A_FAIL_ONCE} = 0;

my $coverage_data = [
    {
        'test'       => 't/integration/coverage/a.tx',
        'manager'    => 'Manager',
        'aggregator' => 'Test2::Harness::Log::CoverageAggregator::ByTest',
        'files'      => {
            'Ax.pm' => {
                '*'  => ['*'],
                'a'  => bag { item {'subtest' => 'b'}; item {'subtest' => 'c'}; item {'subtest' => 'a'} },
                'aa' => [{'subtest' => 'a'}],
            },
            'Bx.pm' => {
                'b' => bag { item {'subtest' => 'b'}; item {'subtest' => 'c'} },
                '*' => ['*'],
            },
            'Cx.pm' => {
                'c' => bag { item '*'; item {'subtest' => 'c'} },
                '*' => ['*'],
            },
        },
    },
    {
        'test'       => 't/integration/coverage/b.tx',
        'aggregator' => 'Test2::Harness::Log::CoverageAggregator::ByTest',
        'files'      => {
            'Bx.pm' => {
                'b' => ['*'],
                '*' => ['*'],
            },
        },
    },
    {
        'test'       => 't/integration/coverage/c.tx',
        'manager'    => 'Manager',
        'aggregator' => 'Test2::Harness::Log::CoverageAggregator::ByTest',
        'files'      => {
            'Ax.pm' => {
                'a' => bag { item {'subtest' => 'c'}; item {'subtest' => 'a'} },
                '*' => [{'subtest' => 'a'}],
            },
            'Cx.pm' => {
                'c' => [{'subtest' => 'c'}],
                '*' => [{'subtest' => 'c'}],
            }
        }
    },
    {
        'aggregator' => 'Test2::Harness::Log::CoverageAggregator::ByTest',
        'test'       => 't/integration/coverage/open.tx',
        'files'      => {'Bx.pm' => {'<>' => ['*']}},
    },
    {
        'test'       => 't/integration/coverage/x.tx',
        'aggregator' => 'Test2::Harness::Log::CoverageAggregator::ByTest',
        'files'      => {'Bx.pm' => {'*' => ['*']}},
    },
];

subtest have_coverage => sub {
    my $schema  = $server->schema_config->schema;
    my $project = $schema->resultset('Project')->find({name => 'test'});
    my $run     = $project->last_covered_run;

    is([$run->coverage_data], $coverage_data, "Got predicted coverage data via DB",);
};

push @yath_args => '--db-coverage';

yath(
    command => 'test',
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v', '--show-changed-files'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
    pre     => ['-D./lib'],
    args    => ["-D$dir/lib", "-I$dir/lib", '--ext=tx', @yath_args, '--plugin' => '+Plugin', '--changed-only', '-v'],
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
