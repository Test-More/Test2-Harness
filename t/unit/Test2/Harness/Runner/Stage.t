use Test2::V0;

__END__

package Test2::Harness::Runner::Stage;
use strict;
use warnings;

our $VERSION = '0.001100';

use Long::Jump qw/longjump/;

use parent 'Test2::Harness::IPC::Process';
use Test2::Harness::Util::HashBase qw{ <name };

sub category { $_[0]->{+CATEGORY} //= 'stage' }

sub set_exit {
    my $self = shift;
    my ($runner, $exit, $time) = @_;

    $self->SUPER::set_exit($exit, $time);

    if ($exit != 0) {
        warn "Child stage '$self->{+NAME}' did not exit cleanly ($exit)!\n";
        CORE::exit(1);
    }

    my $pid = fork;
    unless(defined($pid)) {
        warn "Failed to fork";
        CORE::exit(1);
    }

    # In parent we add the replacement process to the watch list
    if ($pid) {
        $runner->watch(ref($self)->new(pid => $pid, name => $self->{+NAME}));
        return;
    }

    # In the child we do the long jump to unwind the stack
    longjump 'Test-Runner-Stage' => $self->{+NAME};

    warn "Should never get here, failed to restart stage";
    CORE::exit(1);
}

1;
