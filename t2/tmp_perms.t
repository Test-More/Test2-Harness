use Test2::V0;
use File::Spec;
use Test2::Harness::Util qw/clean_path/;

my $path = $ENV{TMPDIR};

sub mode { ((stat($_[0]))[2] & 07777) }

is(mode($path), 1777, "tempdir '$path' has mode 1777");

my $system_tmp = $ENV{SYSTEM_TMPDIR};

my $last = $path;
while ($system_tmp) {
    my $next = clean_path(File::Spec->catdir($last, File::Spec->updir()));
    last if $next eq $system_tmp;
    $last = $next;

    my @mode = split //, mode($next);

    shift (@mode) while @mode > 3;
    subtest "parent '$next'" => sub {
        ok($mode[0] >= 5, "Owner permission is 5+");
        ok($mode[1] >= 5, "Group permission is 5+");
        ok($mode[2] >= 5, "World permission is 5+");
    };
}

done_testing;
