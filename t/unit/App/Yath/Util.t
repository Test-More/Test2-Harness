use Test2::V0 -target => 'App::Yath::Util';
use Test2::Tools::Spec;

use Test2::Util qw/CAN_REALLY_FORK/;
use Test2::Tools::GenTemp qw/gen_temp/;
use Test2::Harness::Util qw/clean_path/;
use File::Temp qw/tempfile/;
use Cwd qw/cwd/;

use File::Spec;

use App::Yath::Util qw{
    is_generated_test_pl
    find_yath
};

imported_ok qw{
    is_generated_test_pl
    find_yath
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

tests is_generated_test_pl => sub {
    ok(!is_generated_test_pl(__FILE__), "This is not a generated test file");

    my ($fh, $name) = tempfile(UNLINK => 1);
    print $fh "use strict;\nuse warnings;\n# THIS IS A GENERATED YATH RUNNER TEST\ndfasdafas\n";
    close($fh);
    ok(is_generated_test_pl($name), "Found a generated file");
};

done_testing;
