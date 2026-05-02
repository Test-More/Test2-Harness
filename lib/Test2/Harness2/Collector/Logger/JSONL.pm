package Test2::Harness2::Collector::Logger::JSONL;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();
use IO::Handle;
use Test2::Harness2::Util::FileMonitor;
use Test2::Harness2::Util::JSONL::Reader;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use Object::HashBase qw{
    <output_file
    <fh
    <logdir
    <service_name
    <run_id
    <job_id
    <job_try
    <is_run
    <ipcm_info
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Collector::Logger';

# Per-logger leaf name. The on-disk file lives at:
#   runs/<run_id>/events.jsonl.zst              (is_run case)
#   services/<name>/events.jsonl.zst            (global service)
#   runs/<run_id>/services/<name>/events.jsonl.zst  (run-scoped service)
sub log_leaf { 'events' }

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};

    croak "Pass either 'output_file' or 'fh', not both"
        if defined($self->{+OUTPUT_FILE}) && defined($self->{+FH});
}

# The concrete output path is either the caller-supplied output_file
# override, or the role-computed basename with '.jsonl' appended.
# Result is cached back into OUTPUT_FILE so later reads see a stable
# path. When 'fh' is in use the logger writes to the caller's handle
# and has no on-disk path to announce.
sub output_files {
    my $self = shift;

    return () if defined $self->{+FH};

    $self->{+OUTPUT_FILE} //= $self->output_file_basename . '.jsonl.zst';

    return ($self->{+OUTPUT_FILE});
}

sub startup {
    my $self = shift;

    # When the caller hands us an open filehandle we use it as-is, so the
    # caller controls its lifetime and we must not close it on shutdown.
    # Caller-supplied handles are written to as plaintext jsonl -- the
    # caller decides what they want on the other end of that handle.
    if ($self->{+FH}) {
        $self->{+FH}->autoflush(1);
        $self->{_fh_borrowed} = 1;
        return;
    }

    # Compute / fetch the cached path via output_files so the path
    # rules live in one place; ignore the returned list, we just want
    # the side effect of populating OUTPUT_FILE.
    $self->output_files unless defined $self->{+OUTPUT_FILE};

    my $path = $self->{+OUTPUT_FILE};
    if ($path =~ /\.zst\z/) {
        $self->{+FH} = open_zstd_writer($path);
    }
    else {
        open(my $fh, '>', $path)
            or croak "Could not open log file '$path': $!";
        $fh->autoflush(1);
        $self->{+FH} = $fh;
    }
}

sub log_event {
    my $self = shift;
    my ($event) = @_;

    my $fh = $self->{+FH} or return;

    # Always compress {json}+"\n" together so each frame uncompresses
    # to a complete jsonl line; the extract command can then stitch
    # frames by concatenation without re-inserting newlines.
    if (ref($fh) && $fh->isa('Test2::Harness2::Util::Zstd::Writer')) {
        $fh->say($event->as_json);
    }
    else {
        print $fh $event->as_json, "\n";
    }
}

sub shutdown {
    my $self = shift;

    my $fh = delete $self->{+FH} or return;

    # Caller-owned handles are left open for the caller to manage.
    return if delete $self->{_fh_borrowed};

    if (ref($fh) && $fh->isa('Test2::Harness2::Util::Zstd::Writer')) {
        $fh->close;
    }
    else {
        close($fh);
    }
}

sub set_process_info {
    my ($self, %info) = @_;
    $self->{+LOGDIR}       = $info{logdir}       if exists $info{logdir};
    $self->{+SERVICE_NAME} = $info{service_name} if exists $info{service_name};
    $self->{+RUN_ID}       = $info{run_id}       if exists $info{run_id};
    $self->{+JOB_ID}       = $info{job_id}       if exists $info{job_id};
    $self->{+JOB_TRY}      = $info{job_try}      if exists $info{job_try};
    $self->{+IS_RUN}       = $info{is_run}       if exists $info{is_run};
    return;
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

# For the file-backed form the path is the locator. For a caller-supplied
# filehandle we cannot know a stable path, but we can still report the
# fileno and owning pid: on OSes that expose a process's open file
# descriptors (e.g. Linux via /proc/<pid>/fd/<fileno>) the consumer can
# still resolve an underlying path, and even when it cannot the pair makes
# clear why jsonl_file is absent.
sub metadata {
    my $self = shift;
    return {jsonl_file => $self->{+OUTPUT_FILE}} if defined $self->{+OUTPUT_FILE};
    my $fh = $self->{+FH} or return undef;
    return {jsonl_fileno => fileno($fh), pid => $$};
}

# ----------------------------------------------------------------------
# Streamer interface
sub update_type            { 'append' }
sub records_state          { 0 }
sub records_general_events { 1 }

# log_reader returns a FileMonitor wrapping a JSONL::Reader delegate.
# The reader auto-detects the on-disk format from the path suffix
# (.zst -> Zstd::Reader internally; otherwise plain newline-delimited
# input), so consumers see one uniform "ask the monitor; drain the
# delegate" surface for both compressed and uncompressed event logs.
sub log_reader {
    my $class = shift;
    my ($path) = @_;

    my $delegate = Test2::Harness2::Util::JSONL::Reader->new(path => $path);

    return Test2::Harness2::Util::FileMonitor->new(
        file     => $path,
        delegate => $delegate,
    );
}

# ready() peeks (no ack) so fetch_events() can ack the change-signal
# itself. The two methods are paired: ready answers "is there
# anything new?" and fetch_events drains. Either one alone works for
# callers that bypass the other.
sub ready {
    my $class = shift;
    my ($r) = @_;
    return 0 unless $r;
    return 0 unless $r->delegate->exists;
    return $r->peek_changed ? 1 : 0;
}

sub fetch_events {
    my $class = shift;
    my ($r) = @_;
    return unless $r;
    # Ack the change signal regardless of how many lines arrive
    # (read_lines may return 0 lines when the change was an mtime
    # touch with no content delta).
    $r->changed;
    my $delegate = $r->delegate;
    return unless $delegate->exists;
    return $delegate->read_lines;
}

# No state to report for an append-style general-event logger; the
# role requires the method, so return undef rather than producing a
# bogus snapshot.
sub fetch_state { undef }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Logger::JSONL - JSONL file logger for the collector.

=head1 DESCRIPTION

Writes one JSON-encoded L<Test2::Harness2::Event> per line to a file.

=head1 SYNOPSIS

Write events to a path the logger opens for you:

    use Test2::Harness2::Collector::Logger::JSONL;

    my $logger = Test2::Harness2::Collector::Logger::JSONL->new(
        output_file => 'events.jsonl',
    );

Or inline via the collector's C<loggers> list:

    Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL', output_file => 'events.jsonl'],
        ],
    );

Or hand it an already-open filehandle -- useful for streaming events to
STDOUT, a pipe, or any other handle whose lifetime you manage yourself:

    Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL', fh => \*STDOUT],
        ],
    );

=head1 ATTRIBUTES

Exactly one of C<output_file> or C<fh> must be provided.

=over 4

=item output_file

The path to a JSONL file to create and write events into. The logger opens
the file at startup and closes it at shutdown.

=item fh

An already-open writable filehandle. The logger does B<not> close this handle
on shutdown -- it remains the caller's responsibility. Useful for streaming
events to STDOUT, a pipe, or any other long-lived handle.

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
