use Test2::V0;

use App::Yath::Tester qw/yath/;
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });


my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# assert that, regardless of order, the `perl -w` shebang only applies
# to the test file it appears in; see
# https://github.com/Test-More/Test2-Harness/issues/266

yath(
    command => 'test',
    args    => ["$dir/a.tx", "$dir/b.tx", '--ext=tx'],
    exit    => 0,
);

yath(
    command => 'test',
    args    => ["$dir/b.tx", "$dir/a.tx", '--ext=tx'],
    exit    => 0,
);

done_testing;
