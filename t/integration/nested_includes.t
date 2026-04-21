use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

if ($ENV{T2_HARNESS_INCLUDES}) {
    $ENV{T2_HARNESS_INCLUDES} .= ";/foo;/bar;/baz";
}
else {
    $ENV{T2_HARNESS_INCLUDES} = "/foo;/bar;/baz";
}

yath(
    command => 'test',
    args    => [$dir, '--ext=tx'],
    exit    => 0,
);

done_testing;
