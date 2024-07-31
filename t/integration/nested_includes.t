use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

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
    exit    => F(),
    test    => sub {
        my $out = shift;
        use Data::Dumper;
        local $Data::Dumper::Sortkeys = 1;
    },
);



done_testing;
