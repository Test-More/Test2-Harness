package App::Yath::Tester;
use strict;
use warnings;

use App::Yath::Util qw/find_yath/;
use File::Spec;
use File::Temp qw/tempfile tempdir/;

use Carp qw/croak/;

use Importer Importer => 'import';
our @EXPORT = qw/yath_test yath_test_with_log yath_start yath_stop yath_run yath_run_with_log/;

my $pdir = tempdir(CLEANUP => 1);

sub yath_test_with_log {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my $exit = _yath('test', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile));
}

sub yath_test {
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('test', $file, $test, @options);
}

sub yath_start {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'start', @options);
}

sub yath_stop {
    my (@options) = @_;
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my $yath = find_yath;
    my $exit = system($^X, $yath, '-D', 'stop', @options);
}

sub yath_run {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();
    return _yath('run', $file, $test, @options);
}

sub yath_run_with_log {
    local $ENV{YATH_PERSISTENCE_DIR} = $pdir;
    my ($test, @options) = @_;
    my ($pkg, $file) = caller();

    my ($fh, $logfile) = tempfile(CLEANUP => 1, SUFFIX => '.jsonl');
    close($fh);

    my $exit = _yath('run', $file, $test, @options, '-F' => $logfile);

    return ($exit, Test2::Harness::Util::File::JSONL->new(name => $logfile));
}


sub _yath {
    my ($cmd, $file, $test, @options) = @_;

    $file =~ s/\.t2?$//g;
    $file = File::Spec->catfile($file, "$test.tx");

    croak "Could not find test '$test' at '$file'" unless -f $file;

    my $yath = find_yath;

    my $exit = system($^X, $yath, '-D', $cmd, @options, $file);

    return $exit;
}

1;

__END__
use List::Util qw/first/;
use Test2::API qw/context/;
use App::Yath::Util qw/find_yath/;

use File::Spec;

my $dir = first { -d $_ } 't/integration/failure_cases', 'integration/failure_cases', 'failure_cases';

my $yath = first { -f $_ } 'scripts/yath', '../scripts/yath';

$yath ||= find_yath();

my %CUSTOM = (
    "timeout.tx"           => ['--et',       2],
    "post_exit_timeout.tx" => ['--pet',      2],
    "noplan.tx"            => ['--pet',      2],
    "dupnums.tx"           => [],
    "missingnums.tx"       => [],
);

opendir(my $DH, $dir) or die "Could not open directory $dir: $!";

for my $file (readdir($DH)) {
    yath_test($file);
}

sub yath_test {
    my ($file) = @_;
    my $path = File::Spec->canonpath("$dir/$file");
    return unless -f $path;
    my $args = $CUSTOM{$file};

    my $ctx = context();

    my @cmd = ($yath, 'test', '-qq', ($args ? @$args : ()), $path);

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
