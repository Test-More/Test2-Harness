use Test2::Require::AuthorTesting;
use Test2::V0 -target => "App::Yath::Command::reload";

use ok $CLASS;

use Cwd qw/getcwd/;
my $orig = getcwd();

use Test2::Tools::HarnessTester -yath_script => 'scripts/yath', qw/run_yath_command run_command make_example_dir/;

use App::Yath::Util qw/PFILE_NAME/;
use Test2::Harness::Util::File::JSON;

my $dir = make_example_dir();
chdir($dir);

unlink(PFILE_NAME) if -e PFILE_NAME;
my $HUP = 0;
local $SIG{HUP} = sub { $HUP++ };

my $out0 = run_yath_command('reload');
isnt($out0->{exit}, 0, "did not succeed");
is(
    $out0->{stderr},
    "Could not find a persistent yath running.\n",
    "Cannot work without a persistent harness"
);

Test2::Harness::Util::File::JSON->new(name => PFILE_NAME)->write(
    {
        pid => $$,
        dir => $dir,
    }
);

my $out1 = run_yath_command('reload');
is($HUP,          1, "Got SIGHUP");
is($out1->{exit}, 0, "Exit success");
ok(!$out1->{stderr}, "No STDERR");
like(
    $out1->{stdout},
    qr/Sending SIGHUP to $$/,
    "Useful message"
);

open(my $fh, '>', 'BLACKLIST') or die "Could not open blacklist";
print $fh "fake\n";
close($fh);

my $out2 = run_yath_command('reload');
is($HUP, 2, "Got SIGHUP again");
ok(!-e 'BLACKLIST', "Removed blacklist");
is($out2->{exit}, 0, "Exit success");
like(
    $out2->{stdout},
    qr/Deleting module blacklist\.\.\./,
    "Useful message about blacklist"
);
like(
    $out2->{stdout},
    qr/Sending SIGHUP to $$/,
    "Useful message"
);

done_testing;
chdir($orig);
