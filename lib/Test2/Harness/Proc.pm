package Test2::Harness::Proc;
use strict;
use warnings;
use 5.10.0;

use POSIX ":sys_wait_h";
use Carp qw/croak/;

use Test2::Util::HashBase qw{
    file id

    tmpdir environment switches libs

    _exit_code _stdout _stderr

    pid
};

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    die "Invalid file: $self->{FILE}\n"
        unless -f $self->{+FILE};

    croak "No temp dir provided"
        unless $self->{+TMPDIR};

    $self->{+LIBS}        ||= [];
    $self->{+SWITCHES}    ||= [];
    $self->{+ENVIRONMENT} ||= {};
}

sub start {
    my $self = shift;

    croak "Process already started!" if $self->{+PID};

    my $pid = fork // die "Could not fork.";

    if ($pid) {
        $self->{+PID} = $pid;
        return $pid;
    }

    my $ok = eval {
        open(my $output,  '>', $self->output_file) or die "Could not open output file: $!";
        open(my $log,     '>', $self->log_file)    or die "Could not open log file: $!";
        open(my $exit_fh, '>', $self->exit_file)   or die "Could not open exit file: $!";
        open(my $pid_fh,  '>', $self->pid_file)    or die "Could not open pid file: $!";

        close(STDOUT);
        open(STDOUT, '>', $self->stdout_file) or die "Could not open a new STDOUT: $!";

        open(my $olderr, '>&', STDERR) or die "$!";
        close(STDERR);
        open(STDERR, '>', $self->stderr_file) or do {
            print $olderr "Could not create a new STDERR: $! at file " . __FILE__ . " line " . __LINE__ . "\n";
            exit 255;
        };

        select $output; $| = 1;
        select STDERR;  $| = 1;
        select STDOUT;  $| = 1;

        print STDOUT "";
        print STDERR "";

        open(my $out, '<', $self->stdout_file) or die "Could not open STDOUT for reading: $!";
        open(my $err, '<', $self->stderr_file) or die "Could not open STDERR for reading: $!";

        my ($be, $bo) = ("", "");

        my $env = $self->environment;
        $ENV{$_} = $env->{$_} for keys %$env;
        $ENV{TMPDIR} = $self->{+TMPDIR};

        my $child = fork() // die "Could not spawn child";
        $self->spawn unless $child;
        print $pid_fh "$child\n";
        close($pid_fh);

        my ($done, $exit);
        while(1) {
            no warnings 'void';
            my ($o, $e);
            my $os = sysread($out, $o, 80) // die "Error: $!";
            my $es = sysread($err, $e, 80) // die "Error: $!";

            $os and ($bo .= $o) xor $bo =~ s/^((?:.+[\n\r])+)//
                and print $output "=|\0STDOUT\0|=\n", $1
                and print $log $1;

            $es and ($be .= $e) xor $be =~ s/^((?:.+[\n\r])+)//
                and print $output "=|\0STDERR\0|=\n", $1
                and print $log $1;

            next if $os || $es;

            $done ||= waitpid($child, WNOHANG);
            next unless $done;
            $exit = $? unless defined($exit);

            # Any remaining output
            print $output $o;
            print $output $e;

            print $log $o;
            print $log $e;

            $exit >>= 8;
            print $exit_fh "$exit\n";
            close($exit_fh);

            exit($exit);
        }

        warn "Fell out of the loop";
        exit 255;
    };
    my $err = $@;
    warn $ok ? "fork got past exec" : ($err || "unknown error");
    exit 255;
}

sub spawn {
    my $self = shift;
    exec(
        $^X,
        (map {( '-I' => $_ )} @{$self->{+LIBS}}),
        @{$self->{+SWITCHES}},
        $self->{+FILE}
    );
}

sub unix_exit { shift->{+_EXIT_CODE} }

sub exit_status {
    my $self = shift;
    my $raw = $self->{+_EXIT_CODE};
    return unless defined $raw;
    return ($raw >> 8);
}

sub pid_file {
    my $self = shift;
    return "$self->{+TMPDIR}/PID";
}

sub exit_file {
    my $self = shift;
    return "$self->{+TMPDIR}/EXIT";
}

sub stdout_file {
    my $self = shift;
    return "$self->{+TMPDIR}/STDOUT";
}

sub stderr_file {
    my $self = shift;
    return "$self->{+TMPDIR}/STDERR";
}

sub output_file {
    my $self = shift;
    return "$self->{+TMPDIR}/OUTPUT";
}

sub log_file {
    my $self = shift;
    return "$self->{+TMPDIR}/full_log";
}

sub results_file {
    my $self = shift;
    return "$self->{+TMPDIR}/RESULTS";
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return $self->{+_EXIT_CODE}
        if defined $self->{+_EXIT_CODE};

    my $pid = $self->pid;
    my $ret = waitpid($pid, $flags || 0);
    my $exit = $?;

    return undef if $ret == 0;

    croak "No such process" if $ret == -1;

    $self->{+_EXIT_CODE} = $exit;
}

sub is_done {
    my $self = shift;
    my $exit = $self->wait(WNOHANG);
    return defined($exit) ? 1 : 0;
}

1;
