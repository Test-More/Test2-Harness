use Test2::V0;
# HARNESS-DURATION-LONG

use Test2::API qw/context/;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# Timeouts short enough that the failing run does not sit out the default
# ones. These apply to the failing run only: the passing run has nothing to
# wait for, and a slow or loaded machine can easily take longer than 2 seconds
# to get a test started, which would kill a test that was going to pass.
my %CUSTOM = (
    "timeout.tx"           => ['--et',  2],
    "post_exit_timeout.tx" => ['--pet', 2],
    "noplan.tx"            => ['--pet', 2],
    "dupnums.tx"           => [],
    "missingnums.tx"       => [],
);

opendir(my $DH, $dir) or die "Could not open directory $dir: $!";

for my $file (readdir($DH)) {
    run_test($file);
}

sub run_test {
    my ($file) = @_;
    my $path = File::Spec->canonpath("$dir/$file");
    return unless -f $path;
    my $args = $CUSTOM{$file};

    my $ctx = context();

    yath(
        command => 'test',
        args    => [@{$args || []}, $path],
        env     => {FAILURE_DO_PASS => 0},
        exit    => T(),
    );

    yath(
        command => 'test',
        args    => [$path],
        env     => {FAILURE_DO_PASS => 1},
        exit    => F(),
    );

    $ctx->release;
}

done_testing;
