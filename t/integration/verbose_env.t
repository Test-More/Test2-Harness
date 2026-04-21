use Test2::V0;

use Config qw/%Config/;
use File::Temp qw/tempfile/;
use File::Spec;

use App::Yath2::Tester qw/yath/;

use Test2::Harness2::Util qw/clean_path/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Make it very wrong to start: each --verbose invocation must reset
# the env vars from this bogus value down to the correct integer.
local $ENV{T2_HARNESS_IS_VERBOSE} = 99;
local $ENV{HARNESS_IS_VERBOSE}    = 99;

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
