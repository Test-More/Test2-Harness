use Test2::V0 -target => 'App::Yath::Command::init';

use ok $CLASS;

use Test2::Tools::HarnessTester qw/run_yath_command run_command make_example_dir/;

my $dir = make_example_dir();
chdir($dir);

subtest run_command => sub {
    unlink('test.pl') or die "Could not unlink test.pl"
        if -e 'test.pl';

    my $out = run_yath_command('init');
    note($out->{stdout}) if $out->{stdout};
    is($out->{exit}, 0, "exit success", $out->{stderr});
    ok(-e "test.pl", "created test.pl");

    $out = run_yath_command('init');
    is($out->{exit}, 0, "exit success if run again", $out->{stderr});

    unlink('test.pl') or die "Could not unlink test.pl";

    open(my $fh, '>', 'test.pl') or die "Could not open test.pl";
    print $fh "xx\n";
    close($fh);

    $out = run_yath_command('init');
    isnt($out->{exit}, 0, "Did not exit with success");
    is($out->{stderr}, "'test.pl' already exists, and does not appear to be a yath runner.\n", "Useful error message");

    unlink('test.pl') or die "Could not unlink test.pl";

    $out = run_yath_command('init');
    note($out->{stdout}) if $out->{stdout};
    is($out->{exit}, 0, "exit success", $out->{stderr});
    ok(-e "test.pl", "created test.pl");

    $out = run_command($^X, 'test.pl');
    is($out->{exit}, 0, "test.pl ran with success");
    ok(!$out->{stderr}, "no stderr output");

    require TAP::Parser;
    my $tp = TAP::Parser->new({tap => $out->{stdout}});

    $tp->run();

    ok(!$tp->has_problems, "Output from test.pl is fine if accidentally run through Test2::Harness");

    like(
        [split /\n/, $out->{stdout}],
        bag {
            item qr{\Q( PASSED )  job  1    t/test.t\E};
            item qr{\Q( PASSED )  job  2    t2/t2_test.t\E};
            item qr{All tests were successful!};
            item qr{^\Q1..1\E$};
            item qr{^ok 1 - Passed tests when run by yath$};
            etc;
        },
        "Got essential parts of output needed to verify it ran"
    );
};

subtest run => sub {
    unlink('test.pl') or die "Could not unlink test.pl"
        if -e 'test.pl';

    my $stdout = "";
    {
        local *STDOUT;
        open(STDOUT, '>', \$stdout);
        is($CLASS->run(), 0, "Exit of 0");
        ok(-e 'test.pl', "Added test.pl");

        is($CLASS->run(), 0, "Exit of 0 if we are updating a generated one");

        unlink('test.pl') or die "Could not unlink test.pl";

        open(my $fh, '>', 'test.pl') or die "Could not open test.pl";
        print $fh "xx\n";
        close($fh);
    }

    is(
        $stdout,
        "\nWriting test.pl...\n\n\nWriting test.pl...\n\n",
        "Saw write info both times"
    );

    is(
        dies { $CLASS->run() },
        "'test.pl' already exists, and does not appear to be a yath runner.\n",
        "Cannot override a non-generated test.pl"
    );
};

done_testing;
