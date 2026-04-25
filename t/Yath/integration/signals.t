# HARNESS-CONFLICTS YATH
use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness2::Util::File::JSONL;
use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

for ( 1..10 ) {
    # the tests are flapping when using something like '%INC = %INC'....
    #   make sure the issue is fixed by running them a few times
    my $out = yath(
        prefix => "Try $_: ",
        command => 'test',
        args    => [$dir],
        log     => 0,
        exit    => 0,
    );
}

done_testing;
