use Test2::V0;

__END__

package Test2::Harness::IPC::Process;
use strict;
use warnings;

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
