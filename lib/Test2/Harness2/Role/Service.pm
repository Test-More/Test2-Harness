package Test2::Harness2::Role::Service;
use v5.38;

our $VERSION = '2.000000';

use Time::HiRes qw/sleep/;
use Role::Tiny;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Role for long-lived harness services.

=head1 DESCRIPTION

A service is a loop. Each iteration calls C<should_stop> first; if it returns
true the loop exits cleanly. Otherwise C<tick> is called to do one unit of
work.

When C<tick> returns true (did work), the loop immediately runs another
iteration with no sleep. When C<tick> returns false (idle), the loop sleeps
with an exponential backoff schedule before the next iteration: C<0.05s>,
C<0.1s>, C<0.5s>, then C<1s>. The backoff index resets to zero the next time
C<tick> reports work done.

Sleeping uses L<Time::HiRes/sleep>, which returns early on signal interruption.
A C<SIGUSR1> from another process therefore wakes the sleeping loop immediately
so the next iteration can pick up new work. The role installs a no-op
C<SIGUSR1> handler for the lifetime of C<run> so the signal does not abort the
process.

If the consumer defines C<on_start>, it is called once before the loop begins.
If the consumer defines C<on_stop>, it is called once just before C<run>
returns.

=head1 SYNOPSIS

    package My::Service;
    use v5.38;
    use Object::HashBase qw{ -running };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub tick ($self) {
        # Do one unit of work; return true if work was done, false if idle.
        return 0;
    }

    sub should_stop ($self) {
        return !$self->{+RUNNING};
    }

=cut

requires 'tick';
requires 'should_stop';

my @BACKOFF = (0.05, 0.1, 0.5, 1);

=pod

=head1 REQUIRED METHODS

=over 4

=item $did_work = $service->tick

One iteration of the service's main work. Return a true value to ask the loop
to run another iteration immediately. Return a false value to trigger the
backoff sleep before the next iteration.

=item $bool = $service->should_stop

Return true to exit the loop cleanly. Polled at the top of every iteration,
before C<tick> is called.

=back

=head1 OPTIONAL METHODS

=over 4

=item $service->on_start

Called once at the top of C<run>, after the C<SIGUSR1> handler is installed
and before the loop begins.

=item $service->on_stop

Called once just before C<run> returns, after the loop exits.

=back

=head1 PUBLIC METHODS

=over 4

=item $service->run

Run the service loop until C<should_stop> returns true. Drives C<tick>, the
backoff schedule, and the C<SIGUSR1>-interruptible sleep.

=cut

sub run ($self) {
    local $SIG{USR1} = sub { };
    $self->on_start if $self->can('on_start');

    my $idx = 0;
    until ($self->should_stop) {
        if ($self->tick) {
            $idx = 0;
            next;
        }
        sleep($BACKOFF[$idx]);
        $idx++ if $idx < $#BACKOFF;
    }

    $self->on_stop if $self->can('on_stop');
    return;
}

=pod

=item $service->wake($pid = $$)

Send C<SIGUSR1> to C<$pid> (defaults to the current process). Callers that
have just written new work into the harness database can call this to nudge
a sleeping service loop to wake up immediately.

=back

=cut

sub wake ($self, $pid = $$) {
    kill 'USR1', $pid;
    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
