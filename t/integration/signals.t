use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use Test2::Harness::Util::File::JSONL;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;

for ( 1..10 ) {
    # the tests are flapping when using something like '%INC = %INC'....
    #   make sure the issue is fixed by running them a few times
    my $out = yath(
        command => 'test',
        args    => [$dir],
        log     => 1,
        exit    => 0,
    );

}

done_testing;
