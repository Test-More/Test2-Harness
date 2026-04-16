package Test2::Harness2::Role::Collector::Logger;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

requires 'set_process_info';
requires 'set_ipcm_info';

# Consumers of this role may be plain classes (no new() method) or may be used
# as objects (new() method defined).

sub depends_on { () }

sub log_events { 1 }

sub log_event { }

sub startup  { }
sub shutdown { }
sub failing  { }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Collector::Logger - Role for collector loggers.

=head1 DESCRIPTION

Loggers are plugged into L<Test2::Harness2::Collector> to receive lifecycle
callbacks and (optionally) per-event callbacks during collection.

A logger may be implemented as either a class (with class-method callbacks) or
as an object (with instance-method callbacks). The collector accepts a mix of
either form.

=head1 SYNOPSIS

    package My::Logger;
    use strict;
    use warnings;

    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Logger';

    sub log_event {
        my ($self, $event) = @_;
        # handle $event...
    }

    1;

Then pass it to the collector:

    Test2::Harness2::Collector->spawn(
        launch      => ['perl', 'some_test.t'],
        output_file => 'out.jsonl',
        loggers     => [
            'My::Logger',                       # class name
            My::Logger->new(%args),             # instance
            ['My::Logger', foo => 1, bar => 2], # class + constructor args
        ],
    );

=head1 METHODS

All methods are optional and have sensible default implementations in the role.

=over 4

=item @classes = $logger->depends_on()

Return a list of other logger class names that must also be present for this
logger to work. The collector validates these dependencies during construction.
The default implementation returns an empty list.

=item $bool = $logger->log_events()

When true, L</log_event> will be called for each event produced during
collection. When false, L</log_event> is never called and should be treated as
a no-op. The default implementation returns true.

=item $logger->log_event($event)

Called once for each L<Test2::Harness2::Event> produced during collection. Only
called when L</log_events> returns true.

=item $logger->startup($collector)

Called once when the collector starts, before any events are processed. The
L<Test2::Harness2::Collector> instance is passed as the only argument.

=item $logger->shutdown($collector)

Called once when the collector is done (the collected process has exited and
all streams have been drained). The L<Test2::Harness2::Collector> instance is
passed as the only argument.

=item $logger->failing($bool)

Called exactly once when the collector's auditor transitions from passing to
failing. Not called on processes that finish without ever being marked
failing, and not called when no auditor is in use. A true value (currently
C<1>) is passed as the sole argument.

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
