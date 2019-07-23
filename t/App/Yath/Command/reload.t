use Test2::V0 -target => "App::Yath::Command::reload";

use ok $CLASS;

use Test2::Tools::HarnessTester qw/make_example_dir/;

use App::Yath::Util qw/find_pfile PFILE_NAME/;
use Test2::Harness::Util::File::JSON;

use Cwd qw/getcwd/;
use File::Spec;
my $orig = getcwd();

my $dir = make_example_dir();
chdir($dir);

subtest simple => sub {
    is($CLASS->group,    'persist', "proper group");
    is($CLASS->cli_args, "",        "no cli-args");

    is($CLASS->show_bench,      0, "do not show bench");
    is($CLASS->has_jobs,        0, "No jobs");
    is($CLASS->has_runner,      0, "no runner");
    is($CLASS->has_logger,      0, "no logger");
    is($CLASS->has_display,     0, "no display");
    is($CLASS->manage_runner,   0, "does not manage a runner");
    is($CLASS->always_keep_dir, 0, "Foes nto always keep dir");

    ok($CLASS->summary,     "got summary");
    ok($CLASS->description, "got description");
};

subtest run => sub {
    # Since we want to control our environment, keep this persistence
    # file within the test's temp directory. Otherwise you can get weird
    # errors if you're using the env var and yath to run the test suite
    local $ENV{YATH_PERSISTENCE_DIR} = $dir;

    my $pfile = find_pfile();
    if ($pfile && -e $pfile){
      unlink($pfile);
    }
    my $HUP = 0;
    local $SIG{HUP} = sub { $HUP++ };

    my $one = $CLASS->new;

    is(
        dies { $one->run },
        "Could not find a persistent yath running.\n",
        "Cannot work without a persistent harness"
    );

    $pfile = File::Spec->rel2abs(PFILE_NAME(),$dir);
    Test2::Harness::Util::File::JSON->new(name => $pfile)->write(
        {
            pid => $$,
            dir => $dir,
        }
    );

    my $stdout = "";
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die "Could not open fake STDOUT: $!";
        is($one->run(), 0, "success");
    }

    is($HUP, 1, "Got SIGHUP");
    like(
        $stdout,
        qr/Sending SIGHUP to $$/,
        "Useful message"
    );

    open(my $fh, '>', 'BLACKLIST') or die "Could not open blacklist";
    print $fh "fake\n";
    close($fh);

    $stdout = "";
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout) or die "Could not open fake STDOUT: $!";
        is($one->run(), 0, "success");
    }
    is($HUP, 2, "Got SIGHUP again");
    ok(!-e 'BLACKLIST', "Removed blacklist");
    like(
        $stdout,
        qr/Deleting module blacklist\.\.\./,
        "Useful message about blacklist"
    );
    like(
        $stdout,
        qr/Sending SIGHUP to $$/,
        "Useful message"
    );
};

done_testing;
chdir($orig);
