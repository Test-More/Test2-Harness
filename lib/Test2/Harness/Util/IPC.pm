package Test2::Harness::Util::IPC;
use strict;
use warnings;

our $VERSION = '0.001100';

use Cwd qw/getcwd/;
use Config qw/%Config/;
use Test2::Util qw/CAN_REALLY_FORK/;

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    USE_P_GROUPS
    run_cmd
    swap_io
};

BEGIN {
    if ($Config{'d_setpgrp'}) {
        *USE_P_GROUPS = sub() { 1 };
    }
    else {
        *USE_P_GROUPS = sub() { 0 };
    }
}

if (CAN_REALLY_FORK) {
    *run_cmd = \&_run_cmd_fork;
}
else {
    *run_cmd = \&_run_cmd_spwn;
}

sub swap_io {
    my ($fh, $to, $die) = @_;

    $die ||= sub {
        my @caller = caller;
        my @caller2 = caller(1);
        die("$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2]).\n");
    };

    my $orig_fd;
    if (ref($fh) eq 'ARRAY') {
        ($orig_fd, $fh) = @$fh;
    }
    else {
        $orig_fd = fileno($fh);
    }

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

sub _run_cmd_fork {
    my %params = @_;

    my $cmd = $params{command} or die "No 'command' specified";

    my $pid = fork;
    die "Failed to fork" unless defined $pid;
    return $pid if $pid;
    %ENV = (%ENV, %{$params{env}}) if $params{env};
    setpgrp(0, 0) if USE_P_GROUPS && !$params{no_set_pgrp};

    $cmd = [$cmd->()] if ref($cmd) eq 'CODE';

    if (my $dir = $params{chdir}) {
        chdir($dir) or die "Could not chdir: $!";
    }

    my $stdout = $params{stdout};
    my $stderr = $params{stderr};
    my $stdin  = $params{stdin};

    open(my $OLD_STDERR, '>&', \*STDERR) or die "Could not clone STDERR: $!";

    my $die = sub {
        my $caller1 = $params{caller1};
        my $caller2 = $params{caller2};
        my $msg = "$_[0] at $caller1->[1] line $caller1->[2] ($caller2->[1] line $caller2->[2]).\n";
        print $OLD_STDERR $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDERR, $stderr, $die) if $stderr;
    swap_io(\*STDOUT, $stdout, $die) if $stdout;
    $stdin ? swap_io(\*STDIN,  $stdin,  $die) : close(STDIN);

    exec(@$cmd) or $die->("Failed to exec!");
}

sub _run_cmd_spwn {
    my %params = @_;

    local %ENV = (%ENV, %{$params{env}}) if $params{env};

    my $cmd = $params{command} or die "No 'command' specified";
    $cmd = [$cmd->()] if ref($cmd) eq 'CODE';

    my $cwd;
    if (my $dir = $params{chdir}) {
        $cwd = getcwd();
        chdir($dir) or die "Could not chdir: $!";
    }

    my $stdout = $params{stdout};
    my $stderr = $params{stderr};
    my $stdin  = $params{stdin};

    open(my $OLD_STDIN,  '<&', \*STDIN)  or die "Could not clone STDIN: $!";
    open(my $OLD_STDOUT, '>&', \*STDOUT) or die "Could not clone STDOUT: $!";
    open(my $OLD_STDERR, '>&', \*STDERR) or die "Could not clone STDERR: $!";

    my $die = sub {
        my $caller1 = $params{caller1};
        my $caller2 = $params{caller2};
        my $msg = "$_[0] at $caller1->[1] line $caller1->[2] ($caller2->[1] line $caller2->[2]).\n";
        print $OLD_STDERR $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDIN,  $stdin,  $die) if $stdin;
    swap_io(\*STDOUT, $stdout, $die) if $stdout;
    $stdin ? swap_io(\*STDIN,  $stdin,  $die) : close(STDIN);

    local $?;
    my $pid;
    my $ok = eval { $pid = system 1, @$cmd };
    my $bad = $?;
    my $err = $@;

    swap_io($stdin ? \*STDIN : [0, \*STDIN], $OLD_STDIN, $die);
    swap_io(\*STDERR, $OLD_STDERR, $die) if $stderr;
    swap_io(\*STDOUT, $OLD_STDOUT, $die) if $stdout;

    if ($cwd) {
        chdir($cwd) or die "Could not chdir: $!";
    }

    die $err unless $ok;
    die "Spawn resulted in code $bad" if $bad;
    die "Failed to spawn" unless $pid;

    return $pid;
}

1;
