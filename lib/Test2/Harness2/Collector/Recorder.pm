package Test2::Harness2::Collector::Recorder;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use Test2::Harness2::Util::IPC qw/atomic_pipe_compression_args apply_atomic_pipe_compression/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <events_file
    <pipes
    -collector_uuid
    -collector_name
    -collector_try
    -events_writer
    -finalized
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

The recorder may also be given one or more notification C<pipes>
(L<Atomic::Pipe> objects). Important occurrences -- not every event, only the
ones a monitor cares about -- are sent to every pipe as a single
zstd-compressed atomic message. The base recorder sends one such message when
the collector finishes (L</finalize>); subclasses
(L<Test2::Harness2::Collector::Recorder::Test>) send more, e.g. one per state
transition. A listener opens the read end (an in-process pipe or an on-disk
FIFO) and any number of collectors can write to it.

This base class enforces nothing about the filename it is handed; the caller
chooses the path. Subclasses override L</record_event> to route some events
to additional files.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder;
    use Atomic::Pipe;

    my ($r, $w) = Atomic::Pipe->pair;

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file => "$dir/events.jsonl.zst",
        pipes       => [$w],                       # optional, any number
    );

    $rec->record_event($event);
    $rec->finalize;                                # sends a finalization message

=head1 ATTRIBUTES

=over 4

=item events_file (required)

Path to the multi-frame zstd events file. Opened for append the first time an
event is recorded.

=item pipes => \@pipes

Optional arrayref of notification targets. Each entry is either a live
L<Atomic::Pipe> object (only usable when the collector shares memory with the
listener -- in-process or post-C<fork>) or a C<< { fifo => $path } >> spec,
which the recorder opens as a write-FIFO itself (usable across an C<exec>,
and the portable choice on platforms without inheritable pipe handles). All
pipes receive the same messages.

=back

=cut

sub init ($self) {
    croak "events_file is a required attribute"
        unless defined $self->{+EVENTS_FILE} && length $self->{+EVENTS_FILE};

    $self->{+FINALIZED} = 0;

    if (my $pipes = $self->{+PIPES}) {
        my @coerced = map { $self->_coerce_pipe($_) } @$pipes;
        apply_atomic_pipe_compression($_) for @coerced;
        $self->{+PIPES} = \@coerced;
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

=item $rec->set_collector_info(uuid => $uuid, name => $name, try => $try)

Record the owning collector's identity. The collector calls this so the
recorder can stamp the collector C<uuid> on every notification message and
include the C<name>, events file, and (for test collectors) the C<try> number
in the start message.

=back

=cut

sub set_collector_info ($self, %info) {
    $self->{+COLLECTOR_UUID} = $info{uuid} if exists $info{uuid};
    $self->{+COLLECTOR_NAME} = $info{name} if exists $info{name};
    $self->{+COLLECTOR_TRY}  = $info{try}  if exists $info{try};
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

    $self->_notify_pipes({harness_collector_finalized => {stamp => time}});

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $writer = $self->_events_writer

Lazily open (and cache) the zstd writer for the events file, so a recorder
that records nothing never creates the file.

=item $pipe = $self->_coerce_pipe($thing)

Turn a C<pipes> entry into a live L<Atomic::Pipe>: a blessed object is used
as-is; a C<< { fifo => $path } >> spec is opened as a write-FIFO.

=item $self->_notify_pipes($facet_data)

=item $self->_notify_pipes($facet_data, %collector_extra)

Send one atomic message to every notification pipe: the JSON of an event
whose facets are C<$facet_data> plus a C<harness_collector> facet carrying the
collector C<uuid> and any C<%collector_extra> (the start message adds C<name>,
C<events_file>, and C<try> via L</_start_extra>). A no-op when no pipes were
supplied. Shared with subclasses that notify on other occasions.

=item _collector_extra

=item %extra = $self->_collector_extra

The C<harness_collector> fields that identify the collected thing: its
C<name>, and -- for test collectors -- the C<try> number. Included in the
start and final-state messages.

=item _start_extra

=item %extra = $self->_start_extra

L</_collector_extra> plus the C<events_file> path; the start message adds the
events-file location on top of the identity fields.

=back

=cut

sub _events_writer ($self) {
    return $self->{+EVENTS_WRITER} //= open_zstd_writer($self->{+EVENTS_FILE});
}

sub _coerce_pipe ($self, $thing) {
    return $thing if blessed($thing);

    if (ref($thing) eq 'HASH' && defined $thing->{fifo}) {
        require Atomic::Pipe;
        return Atomic::Pipe->write_fifo($thing->{fifo}, atomic_pipe_compression_args());
    }

    croak "recorder pipe must be an Atomic::Pipe object or a { fifo => \$path } spec";
}

sub _notify_pipes ($self, $facet_data, %collector_extra) {
    my $pipes = $self->{+PIPES} or return;

    my $message = encode_json({
        facet_data => {
            %$facet_data,
            harness_collector => {uuid => $self->{+COLLECTOR_UUID}, %collector_extra},
        },
    });

    for my $pipe (@$pipes) {
        warn "recorder pipe notify failed: $@\n"
            unless eval { $pipe->write_message($message); 1 };
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
    return ($self->_collector_extra, events_file => $self->{+EVENTS_FILE});
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
