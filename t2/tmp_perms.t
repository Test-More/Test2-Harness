use Test2::V0;
use File::Spec;
use Test2::Harness::Util qw/clean_path/;
use Fcntl ':mode';

sub check_perms {
    my $file = shift;
    my $mode = (stat($file))[2];

    my @bad;
    $mode & S_ISVTX or push @bad => "$file does not have sticky-bit";
    $mode & S_IRWXU or push @bad => "$file is not user RWX";
    $mode & S_IRWXG or push @bad => "$file is not group RWX";
    $mode & S_IRWXO or push @bad => "$file is not other RWX";

    return \@bad;
}

my $system_tmp = clean_path($ENV{SYSTEM_TMPDIR});

my $problems = check_perms($system_tmp);
skip_all join ", " => @$problems if @$problems;

my $path = $ENV{TMPDIR};
is(check_perms($path), [], "$path has correct permissions");

my $last = $path;
my $cnt = 0;
while ($system_tmp) {
    my $next = clean_path(File::Spec->catdir($last, File::Spec->updir()));
    last if $next eq $system_tmp;    # We hit system temp, we can stop
    last if $next eq $last;          # We probably hit root
    last if $cnt++ > 10;             # Something went wrong, no need to loop forever
    $last = $next;

    is(check_perms($next), [], "$next has correct permissions");
}

done_testing;
