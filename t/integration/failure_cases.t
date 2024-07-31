use Test2::V0;
# HARNESS-DURATION-LONG

use Test2::API qw/context/;
use App::Yath::Tester qw/yath/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};
use Test2::Plugin::Immiscible(sub { $ENV{TEST2_HARNESS_ACTIVE} ? 1 : 0 });


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

    my @final_args = (@{$args || []}, $path);

    yath(
        command => 'test',
        args    => \@final_args,
        env     => {FAILURE_DO_PASS => 0},
        exit    => T(),
    );

    yath(
        command => 'test',
        args    => \@final_args,
        env     => {FAILURE_DO_PASS => 1},
        exit    => F(),
    );

    $ctx->release;
}

done_testing;
