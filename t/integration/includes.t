use Test2::V0;
use IPC::Cmd qw/can_run/;

use File::Spec;

use App::Yath::Tester qw/yath/;

use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });

use App::Yath::Util qw/find_yath/;
find_yath();    # cache result before we chdir

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

chdir($dir);
$ENV{OLD_PERL5LIB} = $ENV{PERL5LIB} if defined $ENV{PERL5LIB};

yath(
    command => 'test',
    args    => ['default.tx'],
    exit    => 0,
);

yath(
    command => 'test',
    args    => ['-Ixyz', 'default-i.tx'],
    exit    => 0,
);

# Note: This used to test that order was preserved between all flags, that is
# not really viable anymore. If order is that important then specify everything
# with -I in the desired order.
# Now this is just a test that everything is added in a consistent order
yath(
    command => 'test',
    args    => ['-Ia', '-b', '-Ib', '-l', '-Ic', 'order-ibili.tx'],
    exit    => 0,
);

# Note: This used to test that order was preserved between all flags, that is
# not really viable anymore. If order is that important then specify everything
# with -I in the desired order.
# Now this is just a test that everything is added in a consistent order
yath(
    command => 'test',
    args    => ['-Ia', '-l', '-Ib', '-b', '-Ic', 'order-ilibi.tx'],
    exit    => 0,
);

yath(
    command => 'test',
    args    => ['-Ixyz', '--unsafe-inc', 'dot-last.tx'],
    exit    => 0,
);

$ENV{YATH_PERL} = $^X;
yath(
    command => 'test',
    args    => ['-Ixyz', 'not-perl.sh'],
    exit    => 0,
) if can_run('bash');

done_testing;
