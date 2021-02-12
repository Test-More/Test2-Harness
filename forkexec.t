use strict;
use warnings;

my ($do) = @ARGV;

if ($do) {
    print "Got: $do\n";
    my $got = waitpid($do, 0);
    my $err = $?;

    print "Got: $got ($do) err: $err\n";

    exit 0;
}

my $pid = fork();

if ($pid) {
    print "$$ About to exec\n";
    exec($^X, __FILE__, $pid);
}
else {
    sleep 2;
    print "$$ Child Exits\n";
    exit 12;
}
