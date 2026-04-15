package Test2::Harness2::Collector::Handle;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Util::HashBase qw{
    <pid
    <exit_code
};

sub wait {
    my $self = shift;

    # The collector ran inline (e.g. the Win32 non-launch path), so there is
    # nothing to wait on. The exit_code -- if any -- was recorded directly.
    my $pid = $self->{+PID} or return $self->{+EXIT_CODE};

    waitpid($pid, 0);
    return $self->{+EXIT_CODE} = $?;
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

=item pid

The collector process pid, or undef when the collector ran inline (e.g. the
Win32 non-launch path that consumes pre-opened handles in the same process).

=item exit_code

The wait-status integer returned by L</wait>, or undef before L</wait> has
completed. For an inline collector this may be set by the collector itself
to communicate its outcome.

=back

=head1 METHODS

=over 4

=item $exit = $handle->wait

Block until the collector process exits, then return its raw wait-status.
For an inline collector this is a no-op that returns whatever C<exit_code>
was recorded.

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
