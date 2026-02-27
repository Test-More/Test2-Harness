use Test2::V0 -target => 'App::Yath::Command::init';

use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;
use App::Yath::Util qw/is_generated_test_pl/;

subtest 'run() creates test.pl in current directory' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $orig = getcwd();

    chdir($dir) or die "Cannot chdir to $dir: $!";

    my $obj = CLASS->new();
    my $ret;
    my $out = intercept { $ret = $obj->run() };

    is($ret, 0, 'run() returns 0 on success');
    ok(-f 'test.pl', 'test.pl was created');
    ok(is_generated_test_pl('test.pl'), 'test.pl is recognized as generated');

    # Verify key content
    my $content = do { open my $fh, '<', 'test.pl' or die $!; local $/; <$fh> };
    like($content, qr/GENERATED YATH RUNNER TEST/, 'contains generated marker');
    like($content, qr/find_yath/, 'contains find_yath call');

    chdir($orig) or die "Cannot chdir back: $!";
};

subtest 'run() overwrites a previously generated test.pl' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $orig = getcwd();

    chdir($dir) or die "Cannot chdir to $dir: $!";

    my $obj = CLASS->new();
    intercept { $obj->run() };
    ok(-f 'test.pl', 'first test.pl created');

    # Run again - should succeed (overwrite)
    my $ret;
    intercept { $ret = CLASS->new()->run() };
    is($ret, 0, 'run() returns 0 when overwriting generated test.pl');

    chdir($orig) or die "Cannot chdir back: $!";
};

subtest 'run() dies if test.pl exists and is not generated' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $orig = getcwd();

    chdir($dir) or die "Cannot chdir to $dir: $!";

    # Create a non-generated test.pl
    open my $fh, '>', 'test.pl' or die $!;
    print $fh "#!/usr/bin/perl\nuse Test::More;\ndone_testing;\n";
    close $fh;

    my $obj = CLASS->new();
    like(
        dies { $obj->run() },
        qr/already exists.*does not appear/,
        'dies when test.pl is not a generated file',
    );

    chdir($orig) or die "Cannot chdir back: $!";
};

done_testing;
