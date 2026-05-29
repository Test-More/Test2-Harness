package Test2::Harness2::Collector::Recorder;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

use Object::HashBase qw{
    <events_file
    <touchfile
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
event. When the run ends the collector calls L</finalize>, which closes the
file and, if a C<touchfile> was supplied, updates its mtime so an
inotify-based monitor wakes up.

This base class enforces nothing about the filename it is handed; the caller
chooses the path. Subclasses (e.g. L<Test2::Harness2::Collector::Recorder::Test>)
override L</record_event> to route some events to additional files.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Recorder;

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file => "$dir/events.jsonl.zst",
        touchfile   => "$dir/touch",          # optional
    );

    $rec->record_event($event);
    $rec->finalize;

=head1 ATTRIBUTES

=over 4

=item events_file (required)

Path to the multi-frame zstd events file. Opened for append the first time an
event is recorded.

=item touchfile

Optional path. When set, L</finalize> updates the file's mtime (creating it
if absent) so monitors watching it via inotify are woken when the collector
finishes.

=back

=cut

sub init ($self) {
    croak "events_file is a required attribute"
        unless defined $self->{+EVENTS_FILE} && length $self->{+EVENTS_FILE};

    $self->{+FINALIZED} = 0;

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

Close the events file and, when a C<touchfile> was supplied, touch it. Safe
to call more than once -- subsequent calls are no-ops.

=back

=cut

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

    $self->_touch($self->{+TOUCHFILE});

    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $writer = $self->_events_writer

Lazily open (and cache) the zstd writer for the events file, so a recorder
that records nothing never creates the file.

=item $self->_touch($path)

Update C<$path>'s mtime, creating it if absent. A no-op when C<$path> is
undef or empty. Shared with subclasses that touch on other occasions.

=back

=cut

sub _events_writer ($self) {
    return $self->{+EVENTS_WRITER} //= open_zstd_writer($self->{+EVENTS_FILE});
}

sub _touch ($self, $path) {
    return unless defined $path && length $path;

    if (-e $path) {
        my $now = time;
        utime($now, $now, $path) or warn "utime '$path' failed: $!\n";
        return;
    }

    open(my $fh, '>>', $path) or warn "touch '$path' failed: $!\n";
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
