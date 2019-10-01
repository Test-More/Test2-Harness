use Test2::V0;

__END__

package Test2::Harness::IPC;
use strict;
use warnings;

use POSIX;

use Scope::Guard();

use Cwd qw/getcwd/;
use Config qw/%Config/;
use Carp qw/croak confess/;
use Scalar::Util qw/weaken/;
use Time::HiRes qw/sleep time/;

use Test2::Util qw/CAN_REALLY_FORK/;

use Test2::Harness::IPC::Process;

BEGIN {
    if ($Config{'d_setpgrp'}) {
        *USE_P_GROUPS = sub() { 1 };
    }
    else {
        *USE_P_GROUPS = sub() { 0 };
    }

    my %SIG_MAP;
    my @SIGNAMES = split /\s+/, $Config{sig_name};
    my @SIGNUMS  = split /\s+/, $Config{sig_num};
    while (@SIGNAMES || @SIGNUMS) {
        $SIG_MAP{shift(@SIGNAMES)} = shift @SIGNUMS;
    }

    *SIG_MAP = sub() { \%SIG_MAP };
}

if (CAN_REALLY_FORK) {
    *_run_cmd = \&_run_cmd_fork;
}
else {
    *_run_cmd = \&_run_cmd_spwn;
}

use Test2::Harness::Util::HashBase qw{
    <pid
    <guards
    <handlers
    <procs
    <procs_by_cat
    <waiting
    <wait_time
    <started
};

sub init {
    my $self = shift;

    $self->{+PID} = $$;
    $self->{+PROCS} //= {};
    $self->{+PROCS_BY_CAT} //= {};

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+HANDLERS} //= {};
    $self->{+HANDLERS}->{CHLD} //= sub { 1 };
}

sub start {
    my $self = shift;

    return if $self->{+STARTED};
    $self->{+STARTED} = 1;

    $self->check_for_fork();

    for my $sig (qw/INT HUP TERM CHLD/) {
        croak "Signal '$sig' was already set by something else" if defined $SIG{$sig};

        my $guard = Scope::Guard->new(sub {
            confess "IPC signal handler was removed (not simply localized away temporarily)";
        });

        push @{$self->{+GUARDS}} => $guard;
        weaken($self->{+GUARDS}->[-1]);

        $SIG{$sig} = sub { $self->handle_sig($sig, $guard) };
    }
}

sub stop {
    my $self = shift;

    $self->wait(all => 1);

    if ($self->{+GUARDS}) {
        $_->dismiss() for grep { $_ } @{$self->{+GUARDS}};
    }

    delete $SIG{$_} for qw/INT HUP TERM CHLD/;

    $self->{+STARTED} = 0;
}

sub set_sig_handler {
    my $self = shift;
    my ($sig, $sub) = @_;
    $self->{+HANDLERS}->{$sig} = $sub;
}

sub handle_sig {
    my $self = shift;
    my ($sig) = @_;

    return $self->{+HANDLERS}->{$sig}->($sig) if $self->{+HANDLERS}->{$sig};

    $self->stop();
    exit($self->sig_exit_code($sig));
}

sub sig_exit_code {
    my $self = shift;
    my ($sig) = @_;
    return 128 + SIG_MAP->{$sig};
}

sub killall {
    my $self = shift;
    my ($sig) = @_;
    $sig //= 'TERM';

    $self->check_for_fork();

    $sig = "-$sig" if USE_P_GROUPS;

    kill($sig, keys %{$self->{+PROCS}});
}

sub check_timeouts {}

sub check_for_fork {
    my $self = shift;

    return 0 if $self->{+PID} == $$;

    $self->{+PROCS}   = {};
    $self->{+WAITING} = {};
    $self->{+PID}     = $$;

    return 1;
}

sub _bring_out_yer_dead {
    my $self = shift;

    my $procs   = $self->{+PROCS}   //= {};
    my $waiting = $self->{+WAITING} //= {};

    # Wait on any/all pids
    my $found = 0;
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $exit = $?;
        die "waitpid returned pid '$pid', but we are not monitoring that one!" unless $procs->{$pid};
        $found++;
        $waiting->{$pid} = [$exit, time()];
    }

    return $found;
}

sub _check_if_dead_yet {
    my $self = shift;

    my $procs     = $self->{+PROCS}        //= {};
    my $cat_procs = $self->{+PROCS_BY_CAT} //= {};
    my $waiting   = $self->{+WAITING}      //= {};

    my $found = 0;
    for my $pid (keys %$waiting) {
        next if USE_P_GROUPS && kill(0, -$pid);
        $found++;
        my $exit = delete $waiting->{$pid};
        my $proc = delete $procs->{$pid};
        delete $cat_procs->{$proc->category};
        $proc->set_exit($self, @$exit);
    }

    return $found;
}

sub _ex_parrots {
    my $self = shift;

    my $procs     = $self->{+PROCS}        //= {};
    my $cat_procs = $self->{+PROCS_BY_CAT} //= {};
    my $waiting   = $self->{+WAITING}      //= {};

    my $found = 0;
    for my $pid (keys %$procs) {
        next if $waiting->{$pid};
        next if kill(0, $pid);
        $found++;
        warn "Process $pid vanished!";
        $waiting->{$pid} = [-1, time()];
    }

    return $found;
}

sub wait {
    my $self   = shift;
    my %params = @_;

    $self->check_for_fork();

    my $procs     = $self->{+PROCS}        //= {};
    my $cat_procs = $self->{+PROCS_BY_CAT} //= {};
    my $waiting   = $self->{+WAITING}      //= {};

    return 0 unless keys(%$procs) || keys(%$waiting);

    my $found = 0;
    while (1) {
        $self->check_timeouts;

        $found += $self->_bring_out_yer_dead();
        $found += $self->_check_if_dead_yet();

        my $done = $params{block} ? $found : 1;

        $done = 0 if $params{all}     && keys %$procs;
        $done = 0 if $params{all_cat} && keys %{$cat_procs->{$params{all_cat}}};

        last if $done;

        # This is expensive, so only do it if we are gonna end up waiting
        # anyway If we do find anything here do not bother waiting.
        next if $self->_ex_parrots();

        sleep($self->{+WAIT_TIME}) if $self->{+WAIT_TIME};
    }

    return $found;
}

sub swap_io {
    my $class = shift;
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

sub watch {
    my $self = shift;
    my ($proc) = @_;

    $self->check_for_fork();

    my $pid = $proc->pid or confess "Process has no pid";
    $pid = abs($pid) if USE_P_GROUPS;

    croak "Already watching pid $pid" if exists $self->{+PROCS}->{$pid};

    $self->{+PROCS}->{$pid} = $proc;
    $self->{+PROCS_BY_CAT}->{$proc->category}->{$pid} = $proc;
}

sub spawn {
    my $self = shift;
    my ($proc, $params);
    if (@_ == 1) {
        $proc = shift(@_);
        $params = $proc->spawn_params;
    }
    else {
        $params = {@_};
        my $class = $params->{process_class} // 'Test2::Harness::IPC::Process';
        $proc = $class->new();
    }

    croak "No 'command' specified" unless $params->{command};

    my $caller1 = [caller()];
    my $caller2 = [caller(1)];

    my $env = $params->{env_vars} // {};

    $self->check_for_fork();

    my $pid = $self->_run_cmd(env => $env, caller1 => $caller1, caller2 => $caller2, %$params);
    $proc->set_pid($pid);

    $self->watch($proc);
    return $proc;
}

sub _run_cmd_fork {
    my $self = shift;
    my %params = @_;

    my $cmd = $params{command} or die "No 'command' specified";

    my $pid = fork;
    die "Failed to fork" unless defined $pid;
    return $pid if $pid;
    %ENV = (%ENV, %{$params{env}}) if $params{env};
    setpgrp(0, 0) if USE_P_GROUPS;

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

    $self->swap_io(\*STDERR, $stderr, $die) if $stderr;
    $self->swap_io(\*STDOUT, $stdout, $die) if $stdout;
    $stdin ? $self->swap_io(\*STDIN,  $stdin,  $die) : close(STDIN);

    exec(@$cmd) or $die->("Failed to exec!");
}

sub _run_cmd_spwn {
    my $self = shift;
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

    $self->swap_io(\*STDIN,  $stdin,  $die) if $stdin;
    $self->swap_io(\*STDOUT, $stdout, $die) if $stdout;
    $stdin ? $self->swap_io(\*STDIN,  $stdin,  $die) : close(STDIN);

    local $?;
    my $pid;
    my $ok = eval { $pid = system 1, @$cmd };
    my $bad = $?;
    my $err = $@;

    $self->swap_io($stdin ? \*STDIN : [0, \*STDIN], $OLD_STDIN, $die);
    $self->swap_io(\*STDERR, $OLD_STDERR, $die) if $stderr;
    $self->swap_io(\*STDOUT, $OLD_STDOUT, $die) if $stdout;

    if ($cwd) {
        chdir($cwd) or die "Could not chdir: $!";
    }

    die $err unless $ok;
    die "Spawn resulted in code $bad" if $bad;
    die "Failed to spawn" unless $pid;

    return $pid;
}

1;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC - Base class for modules that control child processes.

=head1 DESCRIPTION

B<PLEASE NOTE:> Test2::Harness is still experimental, it can all change at any
time. Documentation and tests have not been written yet!

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

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
