package Test2::Harness::Util::IPC;
use strict;
use warnings;

our $VERSION = '0.001080';

use POSIX;

use Importer Importer => 'import';

our @EXPORT_OK = qw/run_cmd swap_io/;

sub swap_io {
    my ($fh, $to, $die) = @_;

    $die ||= sub {
        my @caller = caller;
        my @caller2 = caller(1);
        die("$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n");
    };

    my $orig_fd = fileno($fh);
    $die->("Could not get original fd ($fh)") unless defined $orig_fd;

    if (ref($to)) {
        my $mode = $orig_fd ? '>&' : '<&';
        open($fh, $mode, $to) or $die->("Could not redirect output: $!");
    }
    else {
        my $mode = $orig_fd ? '>' : '<';
        open($fh, $mode, $to) or $die->("Could not redirect output to '$to': $!");
    }

    return if fileno($fh) == $orig_fd;

    $die->("New handle does not have the desired fd!");
}

sub run_cmd {
    my %params = @_;

    my $cmd = $params{command} or die "No 'command' specified";

    my $pid = fork;
    die "Failed to fork" unless defined $pid;
    return $pid if $pid;

    my $stdout = $params{stdout};
    my $stderr = $params{stderr};
    my $stdin  = $params{stdin};

    open(my $OLD_STDERR, '>&', \*STDERR) or die "Could not clone STDERR: $!";

    my $die = sub {
        my @caller = caller;
        my @caller2 = caller(1);
        my $msg = "$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n";
        print $OLD_STDERR $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDERR, $stderr, $die) if $stderr;
    swap_io(\*STDOUT, $stdout, $die) if $stdout;
    swap_io(\*STDIN,  $stdin,  $die) if $stdin;

    if (my $dir = $params{chdir}) {
        chdir($dir) or die "Could not chdir: $!";
    }

    $cmd = [$cmd->()] if ref($cmd) eq 'CODE';

    exec(@$cmd) or $die->("Failed to exec!");
}

1;
