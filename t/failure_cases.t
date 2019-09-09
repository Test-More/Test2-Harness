use Test2::V0;
# HARNESS-DURATION-LONG

use List::Util qw/first/;
use Test2::API qw/context/;
use App::Yath::Util qw/find_yath/;

use File::Spec;

my $dir = first { -d $_ } 't/failure_cases', 'failure_cases';

my $yath = first { -f $_ } 'scripts/yath', '../scripts/yath';

$yath ||= find_yath();

my %CUSTOM = (
    "timeout.tx"           => ['--et',       2],
    "post_exit_timeout.tx" => ['--pet',      2],
    "noplan.tx"            => ['--pet',      2],
    #"dupnums.tx"           => ['--no-quiet', '-v'],
    #"missingnums.tx"       => ['--no-quiet', '-v'],
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

    my @cmd = ($yath, 'test', '-q', ($args ? @$args : ()), $path);

    {
        local $ENV{FAILURE_DO_PASS} = 0;
        system($^X, (map { "-I$_" } @INC), @cmd);
        my $fail_exit = $?;
        $ctx->ok($fail_exit, "$file failure case was a failure ($fail_exit)", ["Command: " . join " " => @cmd]);
    }

    {
        local $ENV{FAILURE_DO_PASS} = 1;
        system($^X, (map { "-I$_" } @INC), @cmd);
        my $pass_exit = $?;
        $ctx->ok(!$pass_exit, "$file failure passes when failure cause is removed ($pass_exit)", ["Command: " . join " " => @cmd]);
    }

    $ctx->release;
}

done_testing;
