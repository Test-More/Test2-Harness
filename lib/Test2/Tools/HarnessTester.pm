package Test2::Tools::HarnessTester;
use strict;
use warnings;

our $VERSION = '0.001027';

use IPC::Open3 qw/open3/;
use Test2::Harness::Util qw/open_file/;
use List::Util qw/first/;
use File::Spec;

use Importer Importer => 'import';

our @EXPORT_OK = qw/run_yath_command run_command/;

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

1;
