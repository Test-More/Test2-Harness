package Test2::Harness2::Role::Collector::Logger;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;

use Role::Tiny;

# ----------------------------------------------------------------------
# Streamer interface (class methods)
#
# A logger participates in event streaming (offline or when re-reading a
# static log archive) by answering a small set of class methods that
# describe its on-disk format and let a consumer pull events out.
#
#   $style = $class->update_style()
#       Required. Returns 'append' (log file grows, new lines appended)
#       or 'replace' (file is atomically swapped, so the whole file is
#       a fresh snapshot each time).
#
#   $bool = $class->records_state()
#       True if the logger records state (e.g. pass/fail, job list,
#       run status). State loggers feed fetch_state(); the streamer
#       synthesises lifecycle events from the snapshots they produce.
#       Defaults to 0.
#
#   $bool = $class->records_general_events()
#       True if the logger records general event hashes suitable for
#       direct use as Test2::Harness2::Event payloads. Pass-through
#       via fetch_events(). Defaults to 0.
#
#   $r = $class->log_reader($path)
#       Returns an opaque reader object or filehandle used with
#       ready()/fetch_events()/fetch_state(). Each concrete logger
#       chooses what $r is.
#
#   $bool = $class->ready($r)
#       True if $r has more data ready without blocking. Used by
#       streamers that want to drain a log without waiting.
#
#   @events = $class->fetch_events($r)
#       Required for records_general_events loggers. Returns zero or
#       more fully-formed event hashes (shape compatible with
#       Test2::Harness2::Event). Never blocks.
#
#   $state = $class->fetch_state($r)
#       Required for records_state loggers. Returns the most recent
#       state snapshot hash as written by the logger. Never blocks.
requires 'update_style';
requires 'log_reader';
requires 'ready';
requires 'fetch_events';
requires 'fetch_state';

sub records_state          { 0 }
sub records_general_events { 0 }

# Consumers of this role may be plain classes (no new() method) or may be used
# as objects (new() method defined).

# Default no-op implementations. Loggers that need to retain the run/job/ipcm
# info, the auditor, or the cross-logger lookup must override these -- the
# role can't assume every consumer is a blessed hash or wants to track them.
sub set_process_info   { }
sub set_ipcm_info      { }
sub set_auditor        { }
sub set_loggers_lookup { }

# Path-derivation attributes. Default no-op accessors returning undef;
# consumers that want to drive the output_file_basename computation must
# shadow these (typically via Object::HashBase slots). None of the
# attributes is required at construction time, but output_file_basename
# needs the appropriate subset to be populated before it runs.
sub logdir       { undef }
sub service_name { undef }
sub job_id       { undef }
sub run_id       { undef }
sub job_try      { undef }
sub is_run       { 0 }

sub depends_on { () }

sub applicable { 1 }

sub metadata { undef }

sub log_events { 1 }

sub log_event { }

sub startup  { }
sub shutdown { }
sub failing  { }

# Build the extension-less output path for this logger from its data
# attributes. Rules (see fix_log_paths / role POD):
#
#   service_name + !run_id              -> $logdir/services/$service_name
#   service_name +  run_id + is_run     -> $logdir/runs/$run_id
#   service_name +  run_id + !is_run    -> $logdir/runs/$run_id/services/$service_name
#   job_id       (+ run_id, job_try)    -> $logdir/runs/$run_id/tests/$job_id
#
# Croaks on the ambiguous case where both service_name and job_id are
# set (the role has no constructor in which to trap this earlier).
# Each concrete logger is expected to take this basename and apply its
# own adjustments (typically an extension) to produce a final path.
sub output_file_basename {
    my $self = shift;

    my $logdir = $self->logdir
        or croak "'logdir' is required to compute output_file_basename";

    my $service_name = $self->service_name;
    my $job_id       = $self->job_id;

    croak "Cannot compute output_file_basename: both 'service_name' and 'job_id' are set"
        if defined($service_name) && defined($job_id);

    my $run_id = $self->run_id;

    if (defined $job_id) {
        croak "'run_id' is required when 'job_id' is set"
            unless defined $run_id;
        return "$logdir/runs/$run_id/tests/$job_id";
    }

    if (defined $service_name) {
        return "$logdir/services/$service_name" unless defined $run_id;
        return "$logdir/runs/$run_id" if $self->is_run;
        return "$logdir/runs/$run_id/services/$service_name";
    }

    croak "Cannot compute output_file_basename: neither 'service_name' nor 'job_id' is set";
}

# Required: return the list of on-disk paths this logger will write to.
# Empty list means "nothing to pre-create" (typical for loggers that
# write via a caller-owned filehandle or that produce no files at all).
# Concrete loggers override.
sub output_files { () }

# Ensure the parent directories of every file returned by output_files
# exist. Called by the collector after logger attributes have been
# populated, so the logger can cache its computed path before startup.
sub prepare_output_locations {
    my $self = shift;

    my @files = $self->output_files;
    for my $file (@files) {
        next unless defined $file && length $file;
        my $dir = dirname($file);
        next unless defined $dir && length $dir && $dir ne '.';
        make_path($dir);
    }

    return;
}

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

=head1 PATH DERIVATION

Every logger exposes six data attributes that the role uses to compute a
default output location. None is required at construction time; callers
populate them before the logger needs its path (typically at construction,
or via C<set_process_info> on a pre-built instance).

=over 4

=item logdir

Base log directory, usually C<$workdir/logs>.

=item service_name

Logical name of the service this logger belongs to. Never combined with
C<job_id>.

=item job_id

UUID of the test this logger belongs to. Never combined with C<service_name>.

=item run_id

Run UUID. Required when C<job_id> is set. Optional for services: set for
services scoped to a run (including the run service itself), unset for
services scoped to the whole harness (e.g. the harness service).

=item job_try

Integer attempt count. Always set when C<job_id> is set; C<0> is a valid
value. Never set when C<service_name> is set.

=item is_run

Boolean flag. True only for the collector that interposes on a run service
(where C<service_name> and C<run_id> happen to match). Callers set this
explicitly rather than relying on C<eq>-comparison of the other attributes.

=back

L</output_file_basename> builds an extension-less path from those attributes
(see source for the exact rules) and croaks on ambiguous combinations.
Concrete loggers typically take the basename and append an extension (or
otherwise adjust it) to produce the final path, then cache it into their
own C<output_file> slot.

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

=item $logger->set_process_info(logdir => ..., service_name => ..., job_id => ..., run_id => ..., job_try => ..., is_run => ...)

Invoked by the collector when a pre-constructed logger instance is handed to
it, so the collector can stamp its identifying data onto the logger. The
default is a no-op; loggers that want to retain these attributes must
override and write them to their own storage.

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

=item $path = $logger->output_file_basename

Build the extension-less default output path from the logger's data
attributes. Croaks when required attributes are missing or when
C<service_name> and C<job_id> are both set.

=item @paths = $logger->output_files

Return the list of on-disk files this logger writes to. Empty list means
nothing to pre-create. Concrete loggers override to include their
computed (or overridden) output path.

=item $logger->prepare_output_locations

Ensure the parent directory of every file in C<output_files> exists.
Called by the collector once the logger's attributes have been populated,
before L</startup> opens any files.

=item $style = $class->update_style()

Required. Returns C<'append'> (log file grows, new lines are written to
the end) or C<'replace'> (file is atomically swapped, so the whole file
is a fresh snapshot each time). Used by streamers to pick an appropriate
watching strategy (tail vs. re-read).

=item $bool = $class->records_state()

True if the logger records state snapshots (e.g. pass/fail, job list,
run status). State loggers feed C<fetch_state()>; the streamer
synthesises lifecycle events from the snapshots they produce. Defaults
to false.

=item $bool = $class->records_general_events()

True if the logger records general event hashes suitable for direct use
as L<Test2::Harness2::Event> payloads. Feeds C<fetch_events()> as
pass-through. Defaults to false.

=item $r = $class->log_reader($path)

Returns an opaque reader object or filehandle used with C<ready()>,
C<fetch_events()> and C<fetch_state()>. Each concrete logger chooses
what C<$r> is; the streamer only holds it and passes it back.

=item $bool = $class->ready($r)

True if C<$r> has more data ready without blocking. Used by streamers
that want to drain a log without waiting.

=item @events = $class->fetch_events($r)

Required for records_general_events loggers. Returns zero or more
fully-formed event hashes (shape compatible with
L<Test2::Harness2::Event>). Must never block.

=item $state = $class->fetch_state($r)

Required for records_state loggers. Returns the most recent state
snapshot hash as written by the logger. Must never block.

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
