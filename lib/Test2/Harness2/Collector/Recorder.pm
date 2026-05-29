package Test2::Harness2::Collector::Recorder;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer compress_blob/;
use Test2::Harness2::Util::Socket qw/connect_unix write_frame/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <events_file
    <transition_sockets
    <collector_uuid
    <collector_name
    <collector_try
    <collector_run_uuid
    <events_writer
    <sockets
    <finalized
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Recorder';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Recorder - Base collector recorder: writes every
event to one jsonl.zst file.

=head1 DESCRIPTION

The sink at the end of the collector pipeline. Each event the pipeline
produces is handed to L</record_event>, which appends it to the
C<events_file> as a multi-frame zstd file -- one self-contained frame per
event.

The recorder may also be given one or more C<transition_sockets> (paths to
unix-domain stream sockets a listener is accepting on). Important occurrences
-- not every event, only the ones a monitor cares about -- are sent to every
socket as a single zstd-compressed frame wrapping a
C<< {type =E<gt> "transition", payload =E<gt> {...}} >> envelope. The recorder
C<connect()>s to each socket at construction. The base recorder sends one such
message when the collector finishes (L</finalize>); subclasses
(L<Test2::Harness2::Collector::Recorder::Test>) send more, e.g. one per state
transition. Each collector gets its own connection, so a listener never sees
two collectors' frames interleaved on one stream.

This base class enforces nothing about the filename it is handed; the caller
chooses the path. Subclasses override L</record_event> to route some events
to additional files.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder;

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file        => "$dir/events.jsonl.zst",
        transition_sockets => ["$dir/transitions.sock"],   # optional, any number
    );

    $rec->record_event($event);
    $rec->finalize;                                # sends a finalization message

=head1 ATTRIBUTES

=over 4

=item events_file (required)

Path to the multi-frame zstd events file. Opened for append the first time an
event is recorded.

=item transition_sockets => \@paths

Optional arrayref of unix-domain socket paths. The recorder C<connect()>s to
each at construction (failing fast if one is not present / not accepting) and
sends every notification message to all of them. A listener -- typically a
L<Test2::Harness2::Collector::Monitor> in C<listen> mode -- accepts the
connections and reads the framed messages.

=back

=cut

sub init ($self) {
    croak "events_file is a required attribute"
        unless defined $self->{+EVENTS_FILE} && length $self->{+EVENTS_FILE};

    $self->{+FINALIZED} = 0;

    # Connect now, storing each handle as it opens so a mid-loop failure can
    # still close the ones already opened before rethrowing.
    $self->{+SOCKETS} = [];
    if (my $paths = $self->{+TRANSITION_SOCKETS}) {
        my $ok = eval {
            push @{$self->{+SOCKETS}} => connect_unix($_) for @$paths;
            1;
        };
        my $err = $@;
        unless ($ok) {
            $self->_close_sockets;
            die $err;
        }
    }

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item record_event

=item $rec->record_event($event)

Append one L<Test2::Harness2::Event> to the events file. When the event still
carries its on-wire C<compressed_form> frame, that frame is written verbatim;
otherwise the event is JSON-encoded and compressed into a fresh frame.

=item finalize

=item $rec->finalize

Close the events file and send a finalization message to every notification
pipe. Safe to call more than once -- subsequent calls are no-ops.

=item $rec->set_collector_info(uuid => $uuid, name => $name, try => $try, run_uuid => $run)

Record the owning collector's identity. The collector calls this so the
recorder can stamp the collector C<uuid> on every notification message and
include the C<name>, events file, C<run_uuid> (when set), and (for test
collectors) the C<try> number in the start message.

=back

=cut

sub set_collector_info ($self, %info) {
    $self->{+COLLECTOR_UUID}     = $info{uuid}     if exists $info{uuid};
    $self->{+COLLECTOR_NAME}     = $info{name}     if exists $info{name};
    $self->{+COLLECTOR_TRY}      = $info{try}      if exists $info{try};
    $self->{+COLLECTOR_RUN_UUID} = $info{run_uuid} if exists $info{run_uuid};
    return;
}

sub record_event ($self, $event) {
    my $writer = $self->_events_writer;

    if (defined(my $compressed = $event->compressed_form)) {
        $writer->print_raw_frame($compressed);
        return;
    }

    $writer->print($event->as_json, "\n");
    return;
}

sub finalize ($self) {
    return if $self->{+FINALIZED};
    $self->{+FINALIZED} = 1;

    if (my $writer = delete $self->{+EVENTS_WRITER}) {
        warn "events file close failed: $@\n" unless eval { $writer->close; 1 };
    }

    $self->_notify_sockets({harness_collector_finalized => {stamp => time}});
    $self->_close_sockets;

    return;
}

sub DESTROY ($self) {
    # Close any transition sockets a recorder that was never finalized left
    # open, so the peer (e.g. a managed monitor) sees the connection close.
    $self->_close_sockets;
    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_close_sockets

Close and forget every connected transition socket. Idempotent; called by both
L</finalize> and C<DESTROY>.

=item $writer = $self->_events_writer

Lazily open (and cache) the zstd writer for the events file, so a recorder
that records nothing never creates the file.

=item $self->_notify_sockets($facet_data)

=item $self->_notify_sockets($facet_data, %collector_extra)

Send one message to every connected transition socket: a
C<< {type =E<gt> "transition", payload =E<gt> {...}} >> envelope whose payload is
an event with facets C<$facet_data> plus a C<harness_collector> facet carrying
the collector C<uuid> and any C<%collector_extra> (the start message adds
C<name>, C<events_file>, and C<try> via L</_start_extra>). The envelope is
JSON-encoded and zstd-compressed once, then the same frame is written to each
socket. A no-op when no transition sockets were supplied. Shared with
subclasses that notify on other occasions.

=item _collector_extra

=item %extra = $self->_collector_extra

The C<harness_collector> fields that identify the collected thing: its
C<name>, and -- for test collectors -- the C<try> number. Sent once, in the
start message; later messages carry only the C<uuid> since consumers track
state across messages.

=item _start_extra

=item %extra = $self->_start_extra

L</_collector_extra> plus the C<events_file> path and, when set, the
C<run_uuid>; the start message adds the events-file location and run
association on top of the identity fields.

=back

=cut

sub _events_writer ($self) {
    return $self->{+EVENTS_WRITER} //= open_zstd_writer($self->{+EVENTS_FILE});
}

sub _close_sockets ($self) {
    my $sockets = delete $self->{+SOCKETS} or return;
    for my $sock (@$sockets) {
        eval { close($sock); 1 };
    }
    return;
}

sub _notify_sockets ($self, $facet_data, %collector_extra) {
    my $sockets = $self->{+SOCKETS};
    return unless $sockets && @$sockets;

    my $envelope = encode_json({
        type    => 'transition',
        payload => {
            facet_data => {
                %$facet_data,
                harness_collector => {uuid => $self->{+COLLECTOR_UUID}, %collector_extra},
            },
        },
    });

    my $frame = compress_blob($envelope);

    for my $sock (@$sockets) {
        warn "recorder transition socket write failed: $@\n"
            unless eval { write_frame($sock, $frame); 1 };
    }

    return;
}

sub _collector_extra ($self) {
    return (
        name => $self->{+COLLECTOR_NAME},
        (defined $self->{+COLLECTOR_TRY} ? (try => $self->{+COLLECTOR_TRY}) : ()),
    );
}

sub _start_extra ($self) {
    return (
        $self->_collector_extra,
        events_file => $self->{+EVENTS_FILE},
        (defined $self->{+COLLECTOR_RUN_UUID} ? (run_uuid => $self->{+COLLECTOR_RUN_UUID}) : ()),
    );
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
