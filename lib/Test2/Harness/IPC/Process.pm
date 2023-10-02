package Test2::Harness::IPC::Process;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;

use Test2::Harness::Util::HashBase qw{
    <exit <exit_time
    <pid
    +category
};

sub category { $_[0]->{+CATEGORY} //= 'default' }

sub set_pid {
    my $self = shift;
    my ($pid) = @_;

    croak "pid has already been set" if defined $self->{+PID};

    $self->{+PID} = $pid;
}

sub set_exit {
    my $self = shift;
    my ($ipc, $exit, $time) = @_;

    croak "exit has already been set" if defined $self->{+EXIT};

    $self->{+EXIT}      = $exit;
    $self->{+EXIT_TIME} = $time;
}

sub spawn_params {
    my $self = shift;
    my $class = ref($self) || $self;

    croak "Process class '$class' does not implement 'spawn_params()'";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::IPC::Process - Base class for processes controlled by
Test2::Harness::IPC.

=head1 DESCRIPTION

All processes controlled by L<Test2::Harness::IPC> should subclass this one.

=head1 ATTRIBUTES

=over 4

=item $int = $proc->exit

Exit value, if set. Otherwise C<undef>.

=item $stamp = $proc->exit_time

Timestamp of the process exit, if set, otherwise C<undef>.

=item $pid = $proc->pid

Pid of the process, if it has been started.

=item $cat = $proc->category

Set at construction, C<'default'> if not provided.

=back

=head1 METHODS

=over 4

=item $opt->set_pid($pid)

Set the process id.

=item $opt->set_exit($ipc, $exit, $time)

Set the process as complete. $exit should be the exit value. $time should be a
timestamp. $ipc is an instance of L<Test2::Harness::IPC>.

=item $hashref = $opt->spawn_params()

Used when spawning the process, args go to C<run_cmd()> from
L<Test2::Harness::Util::IPC>.

The base class throws an exception if this method is called.

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
