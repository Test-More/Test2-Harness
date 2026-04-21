package Test2::Harness2::Role::Collector::Logger;
use strict;
use warnings;

our $VERSION = '2.000011';

use Role::Tiny;

# Consumers of this role may be plain classes (no new() method) or may be used
# as objects (new() method defined).

# Default no-op implementations. Loggers that need to retain the run/job/ipcm
# info, the auditor, or the cross-logger lookup must override these -- the
# role can't assume every consumer is a blessed hash or wants to track them.
sub set_process_info   { }
sub set_ipcm_info      { }
sub set_auditor        { }
sub set_loggers_lookup { }

sub depends_on { () }

sub applicable { 1 }

sub metadata { undef }

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

=item $bool = $logger_or_class->applicable($collector)

Return true when this logger makes sense for C<$collector>'s context,
false to have the collector skip it.  Called as either a class or an
instance method against every configured logger spec before the loggers
are instantiated.  Non-applicable loggers are dropped from the collector
entirely -- they are not constructed, do not receive lifecycle hooks,
and do not contribute metadata.

Typical use is to restrict a logger to either service collectors
(harness-level interpose) or test-job collectors.  Since job collectors
are the ones that have an auditor attached, a logger that only makes
sense for a test job can check C<< $collector->auditor >>.

The default implementation returns true (applicable in every context).

=item \%info_or_undef = $logger->metadata()

Return a hashref describing where and how the data this logger produced can
be retrieved by an external consumer.  For a file-backed logger this is
typically a path (e.g. C<< { jsonl_file => '/path/to/events.jsonl' } >>).
Loggers that do not persist retrievable data (for example, loggers that
fire transient IPC messages) should return C<undef> -- the default -- so
downstream consumers see nothing to chase.

The collector gathers each logger's metadata after L</startup> runs and
forwards it to its configured IPC peer so the harness service can publish a
C<job_loggers> event describing where the job's outputs live.  Keyed by
class name, the payload shape is:

    {
        'Logger::Class::A' => [ { ...metadata... }, ... ],
        'Logger::Class::B' => [ { ...metadata... } ],
    }

The value is always an arrayref because the same logger class may be
configured more than once (for example, two JSONL loggers writing to
different files).  Loggers that return C<undef> are omitted entirely: a
class with no defined metadata does not appear in the hash at all.  If no
configured logger returns metadata the event still fires, but with an
empty C<loggers> hash, so downstream consumers always see the message.

The default implementation returns C<undef>.

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

=item $logger->set_process_info(run_id => ..., job_id => ..., job_try => ...)

Invoked by the collector when a pre-constructed logger instance is handed to
it, so the collector can stamp its run/job identifiers onto the logger. The
default is a no-op; loggers that want to retain these identifiers must
override.

=item $logger->set_ipcm_info($info)

Invoked by the collector when a pre-constructed logger instance is handed to
it, so the collector can share its IPC::Manager info. The default is a no-op;
loggers that talk to a service must override.

=item $logger->set_auditor($auditor)

Invoked by the collector after instantiation so loggers that consult the
auditor (e.g. for pass/fail summaries) can capture it. The default is a no-op.

=item $logger->set_loggers_lookup(\%lookup)

Invoked by the collector after instantiation with a reference to the
collector's own C<< $class => [@instances] >> lookup hash. Loggers that need
to consult siblings (for example, a logger that reads from another logger's
state) should store this and B<weaken> their copy to avoid a reference
cycle. The hash stays in sync with the collector's own state, so later
additions are visible.

The default implementation is a no-op.

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
