package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '0.001028';

use IPC::Open3 qw/open3/;
use Test2::Harness::Util qw/open_file/;
use List::Util qw/first/;
use File::Temp qw/tempdir/;
use File::Spec;

use Importer Importer => 'import';

our @EXPORT_OK = qw/run_yath_command run_command make_example_dir/;

my ($YATH) = first { -x $_ } 'scripts/yath', '../scripts/yath';
$YATH ||= do {
    require App::Yath::Util;
    App::Yath::Util::find_yath();
};

$YATH = File::Spec->rel2abs($YATH);

sub run_command {
    my (@cmd) = @_;

    pipe(my($r_out, $w_out)) or die "Could not open pipe for STDOUT: $!";
    pipe(my($r_err, $w_err)) or die "Could not open pipe for STDERR: $!";

    my $pid = open3(undef, '>&' . fileno($w_out), '>&' . fileno($w_err), @cmd);
    close($w_out);
    close($w_err);

    my $ret = waitpid($pid, 0);
    my $exit = $?;

    die "Error waiting on child process" unless $ret == $pid;

    return {
        exit => $exit,
        stdout => join("" => <$r_out>),
        stderr => join("" => <$r_err>),
    };

}

sub run_yath_command {
    return run_command($^X, $YATH, @_);
}

sub _gen_passing_test {
    my ($dir, $subdir, $file) = @_;

    my $path = File::Spec->catdir($dir, $subdir);
    my $full = File::Spec->catfile($path, $file);

    mkdir($path) or die "Could not make $subdir subdir: $!"
        unless -d $path;

    open(my $fh, '>', $full);
    print $fh "use Test2::Tools::Tiny;\nok(1, 'a passing test');\ndone_testing\n";
    close($fh);

    return $full;
}

sub make_example_dir {
    my $dir = tempdir(CLEANUP => 1, TMP => 1);

    _gen_passing_test($dir, 't', 'test.t');
    _gen_passing_test($dir, 't2', 't2_test.t');
    _gen_passing_test($dir, 'xt', 'xt_test.t');

    return $dir;
}

1;
