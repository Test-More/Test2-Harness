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

    my $tmp = gen_temp('bin' => {'yath' => 'xxx'});
    my $yath = clean_path(File::Spec->catfile($tmp, 'bin', 'yath'));
    eval { chmod(0755, File::Spec->catfile($tmp, 'bin', 'yath')); 1 } or warn $@;

    {
        local $ENV{YATH_SCRIPT} = $yath;
        is(find_yath, $yath, "found the yath script named by \$ENV{YATH_SCRIPT}");
        is($App::Yath::Script::SCRIPT, $yath, "cached result");
    }

    # An uninstalled dist: the script lives in blib/script, next to the libs
    # in blib/lib. A local::lib style tree pairs lib/perl5 with bin.
    my $tmp2 = gen_temp(
        blib => {lib   => {}, script => {yath => 'xxx'}},
        lib  => {perl5 => {}},
        bin  => {yath  => 'xxx'},
    );
    my $blib_yath = clean_path(File::Spec->catfile($tmp2, 'blib', 'script', 'yath'));
    my $bin_yath  = clean_path(File::Spec->catfile($tmp2, 'bin',  'yath'));
    eval { chmod(0755, $blib_yath, $bin_yath); 1 } or warn $@;

    # Each search source is checked in isolation: only what the params provide
    # is visible to find_yath.
    my $find = sub {
        my %params = @_;

        $App::Yath::Script::SCRIPT = undef;

        local %ENV = %ENV;
        delete $ENV{YATH_SCRIPT};
        $ENV{YATH_SCRIPT} = $params{env_script} if $params{env_script};
        $ENV{PATH}        = defined $params{path} ? $params{path} : '';

        local @INC                     = @{$params{inc} || []};
        local *App::Yath::Util::Config = $params{config} || {};

        return dies { find_yath } if $params{dies};
        return find_yath;
    };

    my $err = $find->(dies => 1);
    like($err, qr/Could not find the yath script/, "No yath found");
    like($err, qr/^Searched:/m,                    "Error reports what it searched");
    like($err, qr/^Cwd:/m,                         "Error reports the current directory");
    like($err, qr/^PATH:/m,                        "Error reports PATH");
    like($err, qr/^PERL5LIB:/m,                    "Error reports PERL5LIB");
    like($err, qr/^\@INC:/m,                       "Error reports \@INC");

    is($find->(env_script => $yath), $yath, "Found it via \$ENV{YATH_SCRIPT}");

    is(
        $find->(env_script => $yath, inc => [File::Spec->catdir($tmp2, 'blib', 'lib')]),
        $yath,
        "\$ENV{YATH_SCRIPT} outranks the search paths",
    );

    is(
        $find->(inc => [File::Spec->catdir($tmp2, 'blib', 'lib')]),
        $blib_yath,
        "Found blib/script beside a blib/lib in \@INC",
    );

    is(
        $find->(inc => [File::Spec->catdir($tmp2, 'lib', 'perl5')]),
        $bin_yath,
        "Found bin beside a lib/perl5 in \@INC",
    );

    is(
        $find->(config => {scriptdir => File::Spec->catdir($tmp, 'bin')}),
        $yath,
        "Found it in a config path",
    );

    is($find->(path => File::Spec->catdir($tmp, 'bin')), $yath, "Found it in PATH");

    # App::Yath::Script re-execs into a checkout's own script and names it in
    # YATH_SCRIPT, so find_yath does not look for one itself.
    my $checkout = gen_temp('scripts' => {'yath' => 'xxx'});
    eval { chmod(0755, File::Spec->catfile($checkout, 'scripts', 'yath')); 1 } or warn $@;

    chdir($checkout) or die "$!";
    like(
        $find->(dies => 1),
        qr/Could not find the yath script/,
        "A scripts/ dir in the current directory is not searched",
    );
    chdir($initial_dir) or die "$!";

    # An uninstalled script is never in a config path, a lib/perl5 pairing is a
    # guess, so they sit on either side of the config paths.
    is(
        $find->(
            inc    => [File::Spec->catdir($tmp2, 'blib', 'lib')],
            config => {scriptdir => File::Spec->catdir($tmp, 'bin')},
        ),
        $blib_yath,
        "A blib/script dir outranks a config path",
    );

    is(
        $find->(
            inc    => [File::Spec->catdir($tmp2, 'lib', 'perl5')],
            config => {scriptdir => File::Spec->catdir($tmp, 'bin')},
        ),
        $yath,
        "A config path outranks a lib/perl5 pairing",
    );
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

    my ($fh, $name) = tempfile(UNLINK => 1);
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
