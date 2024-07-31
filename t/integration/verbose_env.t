use Test2::V0;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

use Config qw/%Config/;
use File::Temp qw/tempfile/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util       qw/clean_path/;
use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Make it very wrong to start
local $ENV{T2_HARNESS_IS_VERBOSE} = 99;
local $ENV{HARNESS_IS_VERBOSE} = 99;

yath(
    command => 'test',
    args    => [File::Spec->catfile($dir, "not_verbose.tx")],
    exit    => F(),
);

yath(
    command => 'test',
    args    => ['-v', File::Spec->catfile($dir, "verbose1.tx")],
    exit    => F(),
);

yath(
    command => 'test',
    args    => ['-vv', File::Spec->catfile($dir, "verbose2.tx")],
    exit    => F(),
);

done_testing;
