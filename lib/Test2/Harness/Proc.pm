package Test2::Harness::Proc;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;

use Test2::Util::HashBase qw/file pid in_fh out_fh err_fh exit _buffers lines/;

sub init {
    my $self = shift;

    for my $thing (PID(), IN_FH(), OUT_FH(), FILE()) {
        next if $self->{$thing};
        croak "'$thing' is a required attribute";
    }

    $self->{+LINES} = {
        stderr => [],
        stdout => [],
        muxed  => [],
    };

    $self->{+_BUFFERS} = {
        OUT_FH() => "",
        ERR_FH() => "",
    };
}

sub is_done {
    my $self = shift;

    $self->wait(WNOHANG);

    return 1 if defined $self->{+EXIT};
    return 0;
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return if defined $self->{+EXIT};

    my $pid = $self->{+PID} or die "No PID";
    my $ret = waitpid($pid, $flags || 0);
    my $exit = $?;

    return if $ret == 0;
    die "Process $pid was already reaped!" if $ret == -1;

    $exit >>= 8;
    $self->{+EXIT} = $exit;
    return;
}

sub seen_all_lines {
    my $self = shift;
    return @{$self->{+LINES}->{muxed}};
}

sub seen_out_lines {
    my $self = shift;
    return @{$self->{+LINES}->{stdout}};
}

sub seen_err_lines {
    my $self = shift;
    return @{$self->{+LINES}->{stdout}};
}

sub get_out_line {
    my $self = shift;
    return $self->_get_line_for(OUT_FH(), 'stdout', @_);
}

sub get_err_line {
    my $self = shift;
    return $self->_get_line_for(ERR_FH(), 'stderr', @_);
}

sub _get_line_for {
    my $self = shift;
    my ($io_name, $stash, %params) = @_;

    my $h = $self->{$io_name} or return;
    my $buffer = \($self->{+_BUFFERS}->{$io_name});
    my $line = $self->_get_line($h, $buffer, %params);

    return unless $line;

    # Do not stash it if peeking.
    return $line if $params{peek};

    push @{$self->{+LINES}->{$stash}} => $line;
    push @{$self->{+LINES}->{muxed}}  => $line;

    return $line;
}

sub _get_line {
    my $self = shift;
    my ($fh, $buffer, %params) = @_;
    my ($peek, $flush) = @params{qw/peek flush/};
    $flush = 1 if $self->is_done;

    _read($fh, $buffer, $flush);

    my $idx = index($$buffer, "\n");

    unless($idx >= 0) {
        return unless $flush;
        return $$buffer if $peek;

        my $out = $$buffer;
        $$buffer = "";
        return $out;
    }

    return substr($$buffer, 0, $idx + 1) if $peek;
    return substr($$buffer, 0, $idx + 1, "");
}

sub _read {
    my ($fh, $buffer, $flush) = @_;

    while (1) {
        my $got = "";
        my $read = sysread($fh, $got, 1000);
        last unless $read;
        $$buffer .= $got;

        last unless $flush;
    }
}

1;
