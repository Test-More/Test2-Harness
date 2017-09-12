use Test2::V0 -target => 'App::Yath::Util';

use Test2::Tools::GenTemp qw/gen_temp/;

use ok $CLASS => qw/load_command find_yath find_pfile PFILE_NAME find_in_updir read_config/;

imported_ok(qw/load_command find_yath find_pfile PFILE_NAME find_in_updir read_config/);

use Cwd qw/realpath cwd/;

subtest load_command => sub {
    is(load_command('help'), 'App::Yath::Command::help', "Loaded the help command");
    is(
        dies { load_command('a_fake_command') },
        "yath command 'a_fake_command' not found. (did you forget to install App::Yath::Command::a_fake_command?)\n",
        "Exception if the command is not valid"
    );

    local @INC = ('t/lib', @INC);
    like(
        dies { load_command('broken') },
        qr/This command is broken! at/,
        "Exception is propogated if command dies on compile"
    );
};

subtest find_yath => sub {
    require IPC::Cmd;
    my $can_run;
    my $control = mock 'IPC::Cmd' => (
        override => {
            can_run => sub { $can_run },
        },
    );

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

my $tmp = gen_temp(
    '.yath-persist.json' => "XXX",
    'foo'                => "XXX",

    '.yath.rc' => <<"    EOT",
[foo]
-a b c d ; xyz
t t2
--foo
--zoo bar
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
);

my $cwd = cwd();

my $ok = eval {
    chdir(File::Spec->canonpath("$tmp"));
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs('foo')), "Found file in current dir");
    is(find_pfile, realpath(File::Spec->rel2abs('.yath-persist.json')), "Found yath persist file");

    chdir(File::Spec->canonpath("$tmp/dir_a/dir_ab/"));
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs("$tmp/dir_a/foo")), "Found file in updir dir");
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/dir_a/.yath-persist.json")), "Found yath persist file");

    chdir(File::Spec->canonpath("$tmp/dir_b/dir_bb/"));
    is(find_in_updir('foo'), realpath(File::Spec->rel2abs("$tmp/foo")), "Found file in updir/updir dir");
    is(find_pfile, realpath(File::Spec->rel2abs("$tmp/.yath-persist.json")), "Found yath persist file");

    is(
        [read_config('foo')],
        ['-a', 'b c d', 't', 't2', '--foo', '--zoo', 'bar'],
        "Got config for foo command"
    );

    is(
        [read_config('bar')],
        ['-x', 'y', '--xxx', 'xx', '--yyy'],
        "Got config for bar command"
    );

    is(
        [read_config('bub')],
        [],
        "Got config for bar command (empty)"
    );

    1;
};
my $err = $@;

chdir($cwd);

die $err unless $ok;

done_testing;
