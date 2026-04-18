use Test2::V0;
use strict;
use warnings;

BEGIN {
    my $ok = eval { require Linux::Inotify2; 1 };
    plan skip_all => "Linux::Inotify2 not installed" unless $ok;
}

use File::Temp qw/tempdir/;
use File::Spec ();
use Time::HiRes qw/sleep/;

use Test2::Harness2::Reloader::Inotify2;

subtest "detect modify event" => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'w.txt');

    open my $fh, '>', $file or die $!;
    print $fh "start\n";
    close $fh;

    my $r = Test2::Harness2::Reloader::Inotify2->new(stage => 'demo');
    $r->watch($file);
    $r->start;

    is($r->changed_files, [], "no changes initially");

    # Modify the file.
    open my $fh2, '>>', $file or die $!;
    print $fh2 "more\n";
    close $fh2;

    # inotify delivery can be slightly delayed; give it a moment.
    my $changed;
    for (1 .. 20) {
        $changed = $r->changed_files;
        last if $changed && @$changed;
        sleep 0.05;
    }

    ok($changed && @$changed, "inotify reported a change");
    like($changed->[0], qr/\Q$file\E/, "changed file matches");

    $r->stop;
};

done_testing;
