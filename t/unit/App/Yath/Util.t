use Test2::V0 -target => 'App::Yath::Util';
use Test2::Tools::Spec;

use Test2::Util qw/CAN_REALLY_FORK/;
use Test2::Tools::GenTemp qw/gen_temp/;
use Test2::Harness::Util qw/clean_path/;
use File::Temp qw/tempfile/;
use Cwd qw/cwd/;

use File::Spec;

use App::Yath::Util qw{
    find_pfile
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
    find_in_updir
};

imported_ok qw{
    find_pfile
    is_generated_test_pl
    fit_to_width
    isolate_stdout
    find_yath
    find_in_updir
};

my $initial_dir = cwd();
after_each chdir => sub {
    chdir($initial_dir);
};

tests find_yath => sub {
    local $App::Yath::Script::SCRIPT = 'foobar';
    is(find_yath, 'foobar', "Use \$App::Yath::Script::SCRIPT if set");

    $App::Yath::Script::SCRIPT = undef;

    my $tmp = gen_temp('scripts' => {'yath' => 'xxx'});
    my $yath = clean_path(File::Spec->catfile($tmp, 'scripts', 'yath'));
    chdir($tmp);
    eval { chmod(0755, File::Spec->catfile($tmp, 'scripts', 'yath')); 1 } or warn $@;
    is(find_yath, $yath, "found yath script in scripts/ dir");
    is($App::Yath::Script::SCRIPT, $yath, "cached result");

    my $tmp2 = gen_temp();
    chdir($tmp2);

    $App::Yath::Script::SCRIPT = undef;
    local *App::Yath::Util::Config = {};
    like(
        dies { find_yath },
        qr/Could not find yath in Config paths/,
        "No yath found"
    );

    local *App::Yath::Util::Config = {
        scriptdir => File::Spec->catdir($tmp, 'scripts'),
    };
    like(find_yath, qr{\Q$yath\E$}, "Found it in a config path");
};

tests isolate_stdout => sub {
    my ($stdout_r, $stdout_w, $stderr_r, $stderr_w);
    pipe($stdout_r, $stdout_w) or die "Could not open pipe: $!";
    pipe($stderr_r, $stderr_w) or die "Could not open pipe: $!";

    my $pid = fork;
    die "Could not fork" unless defined $pid;

    unless ($pid) { # child
        close($stdout_r);
        close($stderr_r);
        open(STDOUT, '>&', $stdout_w) or die "Could not redirect STDOUT";
        open(STDERR, '>&', $stderr_w) or die "Could not redirect STDOUT";
        my $fh = isolate_stdout();

        print $fh "Should go to STDOUT\n";
        print "Should go to STDERR 1\n";
        print STDOUT "Should go to STDERR 2\n";
        print STDERR "Should go to STDERR 3\n";

        exit 0;
    }

    close($stdout_w);
    close($stderr_w);
    waitpid($pid, 0);
    is($?, 0, "Clean exit");

    is(
        [<$stdout_r>],
        ["Should go to STDOUT\n"],
        "Got expected STDOUT"
    );
    is(
        [<$stderr_r>],
        [
            "Should go to STDERR 1\n",
            "Should go to STDERR 2\n",
            "Should go to STDERR 3\n",
        ],
        "Got expected STDERR"
    );
} if CAN_REALLY_FORK;

subtest is_generated_test_pl => sub {
    ok(!is_generated_test_pl(__FILE__), "This is not a generated test file");

    my ($fh, $name) = tempfile(CLEANUP => 1);
    print $fh "use strict;\nuse warnings;\n# THIS IS A GENERATED YATH RUNNER TEST\ndfasdafas\n";
    close($fh);
    ok(is_generated_test_pl($name), "Found a generated file");
};

subtest find_in_updir => sub {
    my $tmp = gen_temp(
        thefile => 'xxx',
        nest => {
            nest_a => { thefile => 'xxx' },
            nest_b => {},
        },
    );

    chdir(File::Spec->catdir($tmp, 'nest', 'nest_a')) or die "$!";
    my $file = File::Spec->catfile($tmp, 'nest', 'nest_a', 'thefile');
    like(find_in_updir('thefile'), qr{\Q$file\E$}, "Found file in expected spot");

    chdir(File::Spec->catdir($tmp, 'nest', 'nest_b')) or die "$!";
    $file = File::Spec->catfile($tmp, 'thefile');
    like(find_in_updir('thefile'), qr{\Q$file\E$}, "Found file in expected spot");
};

subtest fit_to_width => sub {
    is(fit_to_width(100, " ", "hello there"), "hello there", "No change for short string");
    is(fit_to_width(2, " ", "hello there"), "hello\nthere", "Split across multiple lines");

    is(
        fit_to_width(20, " ", "hello there, this is a longer string that needs splitting."),
        "hello there, this is\na longer string that\nneeds splitting.",
        "Split across multiple lines"
    );

    is(
        fit_to_width(100, " ", ["hello there", "this is a", "longer string that", "needs no splitting."]),
        "hello there this is a longer string that needs no splitting.",
        "Split across multiple lines"
    );

    is(
        fit_to_width(50, " ", ["hello there", "this is a", "longer string that", "needs splitting."]),
        "hello there this is a longer string that\nneeds splitting.",
        "Split across multiple lines"
    );
};

done_testing;
