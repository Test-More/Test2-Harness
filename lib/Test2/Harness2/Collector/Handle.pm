package Test2::Harness2::Collector::Handle;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/WNOHANG/;

use Object::HashBase qw{
    <pid
    exit_code
};

sub init {
    my $self = shift;
    croak "'pid' is a required attribute"
        unless defined $self->{+PID};
}

sub wait {
    my $self = shift;
    return $self->{+EXIT_CODE} if defined $self->{+EXIT_CODE};
    waitpid($self->{+PID}, 0);
    return $self->{+EXIT_CODE} = $?;
}

# Non-blocking completion check. Returns true if the collector process has
# exited, false if it is still running. When the service loop has already
# reaped the pid (IPC::Manager's reap_children runs per-tick) it fills
# exit_code in via set_exit_code, and this short-circuits.
sub is_done {
    my $self = shift;
    return 1 if defined $self->{+EXIT_CODE};

    my $reaped = waitpid($self->{+PID}, WNOHANG);
    if ($reaped > 0) {
        $self->{+EXIT_CODE} //= $?;
        return 1;
    }
    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Handle - Parent-side handle for an in-flight
collector process.

=head1 DESCRIPTION

When L<Test2::Harness2::Collector/start> launches a collector process it
replaces the caller's collector reference with a handle of this class. The
handle exposes the collector pid and a L</wait> method, and is the only
parent-side surface the caller needs to track the running collector.

The collector itself (with all its loggers, parser, auditor, and pipe
machinery) lives in the child process; the parent only ever interacts with
the handle.

=head1 SYNOPSIS

    my $collector = Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        loggers => [ ... ],
    );
    # $collector is now a Test2::Harness2::Collector::Handle

    my $exit = $collector->wait;
    say "collector pid:  ", $collector->pid;
    say "collector exit: ", $collector->exit_code;

=head1 ATTRIBUTES

=over 4

=item pid (required)

The collector process pid.

=item exit_code

The wait-status integer returned by L</wait>, or undef before L</wait> has
completed.

=back

=head1 METHODS

=over 4

=item $exit = $handle->wait

Block until the collector process exits, then return its raw wait-status.

=item $bool = $handle->is_done

Non-blocking completion check. Returns true if the collector process has
already exited, false if it is still running. Also records C<exit_code> on
first successful reap.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
