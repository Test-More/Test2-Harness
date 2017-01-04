package Test2::Harness::Proc;
use strict;
use warnings;

our $VERSION = '0.000014';

use IO::Handle;
use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;

use Test2::Util::HashBase qw/file pid in_fh out_fh err_fh exit lines idx/;

sub init {
    my $self = shift;

    for my $thing (PID(), IN_FH(), OUT_FH(), FILE()) {
        next if $self->{$thing};
        croak "'$thing' is a required attribute";
    }

    for my $fh (@{$self}{OUT_FH(), ERR_FH()}) {
        next unless $fh;
        $fh->blocking(0);
    }

    $self->{+LINES} = {
        stderr => [],
        stdout => [],
        muxed  => [],
    };
}

sub encoding {
    my $self = shift;
    my ($enc) = @_;

    # https://rt.perl.org/Public/Bug/Display.html?id=31923
    # If utf8 is requested we use ':utf8' instead of ':encoding(utf8)' in
    # order to avoid the thread segfault.
    if ($enc =~ m/^utf-?8$/i) {
        binmode($_, ":utf8") for grep {$_} @{$self}{qw/out_fh err_fh in_fh/};
    }
    else {
        binmode($_, ":encoding($enc)") for grep {$_} @{$self}{qw/out_fh err_fh in_fh/};
    }
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

sub force_kill {
    my $self = shift;

    my $pid = $self->{+PID} or die "No PID";
    kill('INT', $pid) or die "Could not signal process";
    $self->{+EXIT} = -1;
    for (1 .. 5) {
        $self->wait(WNOHANG) and last;
        sleep 1 unless $_ >= 5;
    }
}

sub write {
    my $self = shift;
    my $fh = $self->{+IN_FH};
    print $fh @_;
}

sub seen_out_lines {
    my $self = shift;
    return @{$self->{+LINES}->{stdout}};
}

sub seen_err_lines {
    my $self = shift;
    return @{$self->{+LINES}->{stderr}};
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
    my ($io_name, $stash_name, %params) = @_;

    my $stash = $self->{+LINES}->{$stash_name} ||= [];
    my $idx = \($self->{+IDX}->{$stash_name});
    $$idx ||= 0;

    if (@$stash > $$idx) {
        my $line = $stash->[$$idx];
        $$idx++ unless $params{peek};
        return $line;
    }

    my $h = $self->{$io_name} or return;

    seek($h,0,1);
    my $line = <$h>;
    return unless defined $line;

    push @$stash => $line;

    $$idx++ unless $params{peek};

    return $line;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Proc - Handle on a running test process.

=head1 DESCRIPTION

This object is a handle on a running test process. You can use this to check if
the process is still running, send it input, read lines of output, and check
exit value.

=head1 METHODS

=over 4

=item $str = $proc->encoding

Get the encoding (if set).

=item $io = $proc->err_fh

Get the STDERR handle for reading.

=item $io = $proc->out_fh

Get the STDOUT handle for reading.

=item $io = $proc->in_fh

Get the STDIN handle for writing.

=item $exit = $proc->exit

Get the exit value. This will be undefined if the process is still running.

=item $file = $proc->file

Get the filename for the test being run.

=item $line = $proc->get_err_line

=item $line = $proc->get_err_line(peek => 1)

Get a single line of output from STDERR. If peek is set then the line is
remembered and will be retrieved again on the nest call to get_err_line.

=item $proc->get_out_line

=item $proc->get_out_line(peek => 1)

Get a single line of output from STDOUT. If peek is set then the line is
remembered and will be retrieved again on the nest call to get_out_line.

=item $bool = $proc->is_done

Check if the process is done or still running. This also sets the C<exit>
attribute if the process is done.

=item $pid = $proc->pid

PID of the child process.

=item $proc->write($line)

Send data to the child process via it's STDIN.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
