use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;
use File::Copy qw/copy/;

use Test2::Harness::Util::File::JSONL;

use App::Yath::Tester qw/yath/;

use App::Yath::Util qw/find_yath/;
find_yath();    # cache result before we chdir

my $tmp = tempdir(CLEANUP => 1);

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

my $pass  = File::Spec->catfile($tmp, 'pass.tx');
my $pass2 = File::Spec->catfile($tmp, 'pass2.tx');

copy(File::Spec->catfile($dir, 'pass.tx'),  $pass);
copy(File::Spec->catfile($dir, 'pass2.tx'), $pass2);

my $out = yath(command => 'test', args => [$tmp, '--ext=tx'], log => 1, exit => 0);
my $log = $out->{log}->name;

yath(
    command => 'speedtag',
    args    => [$log],
    exit    => 0,
    test    => sub {
        like($_, qr/Tagged .*pass\.tx/,  "Indicate we tagged pass");
        like($_, qr/Tagged .*pass2\.tx/, "Indicate we tagged pass2");

        for my $file ($pass, $pass2) {
            open(my $fh, '<', $file) or die $!;
            my $found = 0;
            while (my $line = <$fh>) {
                chomp($line);
                next unless $line =~ m/^#\s*HARNESS-DURATION-(SHORT|MEDIUM|LONG)$/;
                $found = 1;
                last;
            }
            $file =~ s/^.*(pass\d?\.tx)$/$1/;
            ok($found, "Tagged file $file");
        }
    },
);

done_testing;
