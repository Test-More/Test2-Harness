use Test2::V0;

use App::Yath::Tester qw/yath/;
use File::Temp qw/tempdir/;

use File::Spec;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

my $tmpdir = tempdir(CLEANUP => 1);

yath(
    command => 'test',
    args    => ["--log-dir=$tmpdir", '-L', '--ext=tx', $dir],
    exit    => 0,
    test    => sub {
        my $out = shift;

        opendir(my $dh, $tmpdir) or die "Could not open dir $tmpdir: $!";
        my @files;
        for my $file (readdir($dh)) {
            next if $file =~ m/^\.+$/;
            next unless -f File::Spec->catfile($tmpdir, $file);
            push @files => $file;
        }

        is(@files, 1, "Only 1 file present");
        like($files[0], qr{\.jsonl$}, "File is a jsonl file");
    },
);

done_testing;
