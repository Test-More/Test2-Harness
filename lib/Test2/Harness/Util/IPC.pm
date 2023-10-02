package Test2::Harness::Util::IPC;
use strict;
use warnings;

our $VERSION = '1.000155';

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
    my ($fh, $to, $die, $mode) = @_;

    $die ||= sub {
        my @caller = caller;
        my @caller2 = caller(1);
        die("$_[0] at $caller[1] line $caller[2] ($caller2[1] line $caller2[2], ${ \__FILE__ } line ${ \__LINE__ }).\n");
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
        $mode //= $orig_fd ? '>&' : '<&';
        open($fh, $mode, $to) or $die->("Could not redirect output: $!");
    }
    else {
        $mode //= $orig_fd ? '>' : '<';
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
    if ($pid) {
        $_->() for @{$params{run_in_parent} // []};
        return $pid;
    }
    else {
        $_->() for @{$params{run_in_child} // []};
    }
    %ENV = (%ENV, %{$params{env}}) if $params{env};
    setpgrp(0, 0) if USE_P_GROUPS && !$params{no_set_pgrp};

    $cmd = [$cmd->()] if ref($cmd) eq 'CODE';

    if (my $dir = $params{chdir} // $params{ch_dir}) {
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
    swap_io(\*STDIN,  $stdin,  $die) if $stdin;
    open(STDIN, "<", "/dev/null") if !$stdin;

    @$cmd = map { ref($_) eq 'CODE' ? $_->() : $_ } @$cmd;

    exec(@$cmd) or $die->("Failed to exec!");
}

sub _run_cmd_spwn {
    my %params = @_;

    local %ENV = (%ENV, %{$params{env}}) if $params{env};

    my $cmd = $params{command} or die "No 'command' specified";
    $cmd = [$cmd->()] if ref($cmd) eq 'CODE';

    my $cwd;
    if (my $dir = $params{chdir} // $params{ch_dir}) {
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
        my $msg = "$_[0] at $caller1->[1] line $caller1->[2] ($caller2->[1] line $caller2->[2], ${ \__FILE__ } line ${ \__LINE__ }).\n";
        print $OLD_STDERR $msg;
        print STDERR $msg;
        POSIX::_exit(127);
    };

    swap_io(\*STDIN,  $stdin,  $die) if $stdin;
    swap_io(\*STDOUT, $stdout, $die) if $stdout;
    $stdin ? swap_io(\*STDIN,  $stdin,  $die) : close(STDIN);

    local $?;
    my $pid;
    my $ok = eval { $pid = system 1, map { ref($_) eq 'CODE' ? $_->() : $_ } @$cmd };
    my $bad = $?;
    my $err = $@;

    swap_io($stdin ? \*STDIN : [0, \*STDIN], $OLD_STDIN, $die);
    swap_io(\*STDERR, $OLD_STDERR, $die) if $stderr;
    swap_io(\*STDOUT, $OLD_STDOUT, $die) if $stdout;

    if ($cwd) {
        chdir($cwd) or die "Could not chdir: $!";
    }

    die $err unless $ok;
    die "Spawn resulted in code $bad" if $bad && $bad != $pid;
    die "Failed to spawn" unless $pid;

    $_->() for @{$params{run_in_parent} // []};

    return $pid;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::IPC - Utilities for IPC management.

=head1 DESCRIPTION

This package provides low-level IPC tools for Test2::Harness.

=head1 EXPORTS

All exports are optional and must be specified at import time.

=over 4

=item $bool = USE_P_GROUPS()

This is a shortcut for:

    use Config qw/%Config/;
    $Config{'d_setpgrp'};

=item swap_io($from, $to)

=item swap_io($from, $to, \&die)

This will close and re-open the file handle designated by C<$from> so that it
redirects to the handle specified in C<$to>. It preserves the file descriptor
in the process, and throws an exception if it fails to do so.

    swap_io(\*STDOUT, $fh);
    # STDOUT now points to wherever $fh did, but maintains the file descriptor number '2'.

As long as the file descriptor is greater than 0 it will open for writing. If
the descriptor is 0 it will open for reading, allowing for a swap of C<STDIN>
as well.

Extra effort is made to insure errors go to the real C<STDERR>, specially when
trying to swap out C<STDERR>. If you have trouble with this, or do not trust
it, you can provide a custom coderef as a third argument, this coderef will be
used instead of C<die()> to throw exceptions.

Note that the custom die logic when you do not provide your own bypasses the
exception catching mechanism and will exit your program. If this is not
desirable then you should provide a custom die subref.

=item $pid = run_cmd(command => [...], %params)

This function will run the specified command and return a pid to you. When
possible this will be done via C<fork()> and C<exec()>. When that is not
possible it uses the C<system(1, ...)> trick to spawn a new process. Some
parameters do not work in the second case, and are silently ignored.

Parameters:

=over 4

=item command => [$command, sub { ... }, @args]

=item command => sub { return ($command, @args) }

This parameter is required. This should either be an arrayref of arguments for
C<exec()>, or a coderef that returns a list of arguments for C<exec()>. On
systems without fork/exec the arguments will be passed to
C<system(1, $command, @args)> instead.

If the command arrayref has a coderef in it, the coderef will be run and its
return value(s) will be inserted in its place. This replacement happens
post-chroot

=item run_in_parent => [sub { ... }, sub { ... }]

An arrayref of callbacks to be run in the parent process immedietly after the
child process is started.

=item run_in_child => [sub { ... }, sub { ... }]

An arrayref of callbacks to be run in the child process immedietly after fork.
This parameter is silently ignored on systems without fork/exec.

=item env => { ENVVAR => $VAL, ... }

A hashref of custom environment variables to set in the child process. In the
fork/exec model this is done post-fork, in the spawn model this is done via
local prior to the spawn.

=item no_set_pgrp => $bool,

Normall C<setpgrp(0,0)> is called on systems where it is supported. You can use
this parameter to override the normal behavior. setpgrp() is not called in the
spawn model, so this parameter is silently ignored there.

=item chdir => 'path/to/dir'

=item ch_dir => 'path/to/dir'

chdir() to the specified directory for the new process. In the fork/exec model
this is done post-fork in the child. In the spawn model this is done before the
spawn, then a second chdir() puts the parent process back to its original dir
after the spawn.

=item stdout => $handle

=item stderr => $handle

=item stdin  => $handle

Thise can be used to provide custom STDERR, STDOUT, and STDIN. In the fork/exec
model these are swapped into place post-fork in the child. In the spawn model
the swap occurs pre-spawn, then the old handles are swapped back post-spawn.

=back

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
