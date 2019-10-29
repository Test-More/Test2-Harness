use Test2::V0 -target => 'App::Yath::Command::init';
# HARNESS-DURATION-SHORT

use ok $CLASS;

use Test2::Tools::HarnessTester qw/make_example_dir/;

use Cwd qw/getcwd/;
my $orig = getcwd();

subtest run => sub {
    my $dir = make_example_dir();
    chdir($dir);

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
chdir($orig);
