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
