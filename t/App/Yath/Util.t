use Test2::V0 -target => 'App::Yath::Util';

use Test2::Tools::GenTemp qw/gen_temp/;

use ok $CLASS => qw/find_yath find_pfile PFILE_NAME find_in_updir read_config is_generated_test_pl/;

imported_ok(qw/find_yath find_pfile PFILE_NAME find_in_updir read_config is_generated_test_pl/);

use Cwd qw/realpath cwd/;

subtest find_yath => sub {
    require IPC::Cmd;
    my $can_run;
    my $control = mock 'IPC::Cmd' => (
        override => {
            can_run => sub { $can_run },
        },
    );

    no warnings 'uninitialized';
    local $App::Yath::SCRIPT = undef;
    local $ENV{YATH_SCRIPT}  = undef;
    local $0                 = 'fake';

    like(
        dies { find_yath },
        qr/Could not find 'yath' in execution path/,
        "Dies if yath cannot be found"
    );

    $can_run = 'a_yath';
    is(find_yath, File::Spec->rel2abs('a_yath'), "found via can_run");

    $0 = 'scripts/yath';
    is(find_yath, File::Spec->rel2abs('scripts/yath'), "found via \$0");

    $ENV{YATH_SCRIPT} = 'b_yath';
    is(find_yath, File::Spec->rel2abs('b_yath'), "found via \$ENV{YATH_SCRIPT}");

    $App::Yath::SCRIPT = 'c_yath_run';
    is(find_yath, File::Spec->rel2abs('c_yath_run'), "found via \$App::Yath::SCRIPT");
};

my $tmp = realpath(gen_temp(
    '.yath-persist.json' => "XXX",
    'foo'                => "XXX",

    'test_a.pl' => "\n\n# THIS IS A GENERATED YATH RUNNER TEST\n\n",
    'test_b.pl' => "\n\n# THIS IS NOT A GENERATED YATH RUNNER TEST\n\n",

    '.yath.rc' => <<"    EOT",
[foo]
-a b c d ; xyz
t t2
--foo
--zoo bar
--path rel(./x/y/z)
--path ./x/y/z
;xyz
;[bub]

[bar]
-x y
--xxx xx ; xyz
--yyy

    EOT

    dir_a => {
        '.yath-persist.json' => "XXX",
        'foo'                => "XXX",

        dir_ab => {},
    },

    dir_b => {
        dir_bb => {},
    },
));

my $cwd = cwd();

my $ok = eval {
    # Guard against yath being run with a YATH_PERSISTENCE_DIR
    local $ENV{YATH_PERSISTENCE_DIR} = undef;
    chdir(File::Spec->canonpath("$tmp"));
    is(find_in_updir('A FAKE FILE THAT SHOULD NOT BE ANYWHERE $@!#'), undef, "File not found");
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs('foo')), "Found file in current dir");
    is(find_pfile, realpath(File::Spec->rel2abs('.yath-persist.json')), "Found yath persist file");

    ok(is_generated_test_pl('test_a.pl'), "Is a generated test.pl");
    ok(!is_generated_test_pl('test_b.pl'), "Is not a generated test.pl");

    chdir(File::Spec->canonpath("$tmp/dir_a/dir_ab/"));
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs("$tmp/dir_a/foo")), "Found file in updir dir");
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/dir_a/.yath-persist.json")), "Found yath persist file");

    chdir(File::Spec->canonpath("$tmp/dir_b/dir_bb/"));
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs("$tmp/foo")), "Found file in updir/updir dir");
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/.yath-persist.json")), "Found yath persist file");

    # Explicitly test a YATH_PERSISTENCE_DIR env var
    local $ENV{YATH_PERSISTENCE_DIR} = $tmp;
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/.yath-persist.json")), "Found yath persist file");

    # Make sure that the environment variable is respected by setting
    # the ENV var to a known good folder that is not the CWD
    local $ENV{YATH_PERSISTENCE_DIR} = realpath(File::Spec->rel2abs("$tmp/dir_a"));
    chdir(File::Spec->canonpath("$tmp"));
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/dir_a/.yath-persist.json")), "Found yath persist file");

    is(
        [read_config('foo', file => '.yath.rc', search => 1)],
        ['-a', 'b c d', 't', 't2', '--foo', '--zoo', 'bar', '--path' => File::Spec->canonpath("$tmp/x/y/z"), '--path' => './x/y/z'],
        "Got config for foo command"
    );

    is(
        [read_config('bar', file => '.yath.rc', search => 1)],
        ['-x', 'y', '--xxx', 'xx', '--yyy'],
        "Got config for bar command"
    );

    is(
        [read_config('bub', file => '.yath.rc', search => 1)],
        [],
        "Got config for bar command (empty)"
    );

    1;
};
my $err = $@;

chdir($cwd);

die $err unless $ok;

done_testing;
