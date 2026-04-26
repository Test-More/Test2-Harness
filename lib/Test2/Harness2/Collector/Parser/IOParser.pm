package Test2::Harness2::Collector::Parser::IOParser;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Event;

use Object::HashBase qw{
    <ipcm_info
    <name
    <type
};

sub init {
    my $self = shift;

    croak "'ipcm_info' is a required attribute"
        unless defined $self->{+IPCM_INFO};
}

sub set_ipcm_info {
    my ($self, $info) = @_;
    $self->{+IPCM_INFO} = $info;
    return;
}

sub parse_io {
    my $self = shift;
    my (%params) = @_;

    my $stream = $params{stream} or croak "No 'stream' provided";

    return unless defined $params{line} || defined $params{event};

    my $event = $self->get_event(%params);

    $self->parse_stream_line(\%params, $event) if defined $params{line};

    $self->normalize_event(\%params, $event);

    # Stash the on-wire compressed JSON frame the collector captured
    # from Atomic::Pipe's keep_compressed read path. The bytes are
    # only meaningful for events that came in as a JSON burst and
    # whose body has not been mutated since; auditors that modify
    # the event clear this field via Event::clear_compressed_form so
    # downstream zstd-aware loggers do not write stale frames.
    $event->{compressed_form} = $params{compressed}
        if defined $params{compressed};

    return $event;
}

sub normalize_event {
    my $self = shift;
    my ($io, $event) = @_;

    my $stamp = $event->{stamp} // $io->{stamp} // time;

    croak "event_id mismatch between event ('$event->{event_id}') and io ('$io->{event_id}')"
        if defined($event->{event_id})
        && defined($io->{event_id})
        && $event->{event_id} ne $io->{event_id};

    my $event_id = $event->{event_id} // $io->{event_id} // gen_uuid();

    $event->{stamp}    = $stamp;
    $event->{event_id} = $event_id;

    $event->{facet_data}{harness}{stamp}    = $stamp;
    $event->{facet_data}{harness}{event_id} = $event_id;

    # Only fill in about.uuid when an about facet already exists -- don't
    # autovivify one just to stamp a uuid onto it.
    $event->{facet_data}{about}{uuid} //= $event_id
        if $event->{facet_data}{about};
}

sub get_event {
    my $self = shift;
    my (%params) = @_;

    # Pre-built event (typically decoded from a JSON burst on STDOUT).
    if (my $ev = $params{event}) {
        return $ev if blessed($ev);
        return Test2::Harness2::Event->new(%$ev);
    }

    return Test2::Harness2::Event->new(
        stamp      => $params{stamp}    // time,
        event_id   => $params{event_id} // gen_uuid(),
        facet_data => {},
    );
}

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream   = $io->{stream};
    my $ucstream = uc($stream);

    my $text = $io->{line};
    my $tag  = $ucstream;

    $event->{facet_data}{from_stream} = {source => $ucstream, details => $text};

    push @{$event->{facet_data}{info}} => {
        details => $text,
        tag     => $tag,
        debug   => ($ucstream eq 'STDERR' ? 1 : 0),
    };
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Parser::IOParser - Base parser that turns raw stream lines into events.

=head1 DESCRIPTION

The default parser used by L<Test2::Harness2::Collector>. Given a stream name
(C<stdout> or C<stderr>) and a single line of text, produces a
L<Test2::Harness2::Event> whose facet data wraps the line in a C<from_stream>
facet and a matching C<info> entry. No protocol parsing is attempted; every
line becomes one event verbatim. Subclasses such as
L<Test2::Harness2::Collector::Parser::IOParser::Stream> override
C<parse_stream_line> to recognize richer line formats (e.g. TAP) while
reusing the rest of the pipeline.

The parser also attaches a C<harness> facet carrying the event id and stamp.

This class is instantiated by the collector automatically when no parser is
supplied and at least one logger or an auditor is present; see
L<Test2::Harness2::Collector/loggers> for the surrounding pipeline. Passing a
parser explicitly (either a class name or a constructed instance) overrides
the default.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Parser::IOParser;

    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(ipcm_info => $ii);

    my $event = $parser->parse_io(
        stream => 'stdout',
        line   => 'hello world',
        stamp  => time,
    );

    # $event->facet_data->{from_stream}{source}  eq 'STDOUT'
    # $event->facet_data->{from_stream}{details} eq 'hello world'
    # $event->facet_data->{info}[0]{tag}         eq 'STDOUT'
    # $event->facet_data->{harness}{event_id}    eq $event->event_id

Used via the collector:

    use Test2::Harness2::Collector;

    my $c = Test2::Harness2::Collector->spawn(
        launch => ['perl', '-e', 'print "hi\n"'],
        # No explicit parser -- IOParser is the default when at least one
        # logger or auditor is present.
        loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL',
                output_file => 'events.jsonl'],
        ],
    );

=head1 ATTRIBUTES

Exposed as read-only accessors via L<Object::HashBase>.

=over 4

=item ipcm_info (required)

IPC::Manager route info for the collector pipeline.

=item name

Free-form name slot reserved for callers that want to tag the parser
instance. Not used internally.

=item type

Free-form type slot reserved for callers. Not used internally.

=back

=head1 METHODS

=over 4

=item $event = $parser->parse_io(stream => $stream, line => $line, %opts)

Parse a single line into a single event and return it. Returns C<undef> (not
an event) when C<line> is undefined; the collector uses this as the
end-of-stream signal from its handle reader.

Named parameters:

=over 4

=item stream

Required. Either C<'stdout'> or C<'stderr'>. Any other value is accepted but
will be uppercased into the C<from_stream.source> slot as-is.

=item line

The text of the line (without trailing newline). If undef the method returns
undef without constructing an event.

=item stamp

Optional timestamp. Defaults to the current time from L<Time::HiRes> when
omitted.

=item event_id

Optional pre-assigned UUID. Defaults to a freshly generated UUID when
omitted.

=back

The method orchestrates three steps in order: C<get_event> constructs a
fresh event, C<parse_stream_line> populates the stream-specific facets, and
C<normalize_event> fills in the C<harness> facet and propagates
C<event_id>/C<stamp> into it.

=item $event = $parser->get_event(%params)

Build and return a fresh L<Test2::Harness2::Event> with C<stamp>,
C<event_id>, and an empty C<facet_data> hash. Subclasses can override this
to pre-populate facets or to reuse an existing event passed in via C<%params>.

=item $parser->parse_stream_line(\%io, $event)

Populate C<< $event->{facet_data} >> from a line of stream input. The base
implementation attaches a C<from_stream> facet (source + details) and pushes
a single C<info> entry tagged with the uppercased stream name, with
C<debug = 1> for STDERR and C<debug = 0> otherwise.

Subclasses that recognize richer line formats (TAP, JSON, custom protocols)
override this method. A subclass that successfully parses the line may
replace C<< $event->{facet_data} >> with its own facets and skip the
base-class call; on a miss it can invoke C<< $self->SUPER::parse_stream_line >>
to keep the fallback behavior.

The C<$io> hashref is the same hash of named parameters that was passed to
C<parse_io>; subclasses may mutate it (for example to signal to downstream
code that a line has been consumed).

=item $parser->normalize_event(\%io, $event)

Merge timing information into the event. Sets C<< $event->{stamp} >> and
C<< $event->{event_id} >>, then copies those into
C<< $event->{facet_data}{harness} >>. Safe to call multiple times; existing
C<harness> fields are preserved.

=back

=head1 SUBCLASSING

To add support for a new line protocol, subclass this parser and override
C<parse_stream_line>. The usual pattern is:

    package My::Parser;
    use parent 'Test2::Harness2::Collector::Parser::IOParser';

    sub parse_stream_line {
        my ($self, $io, $event) = @_;

        if (my $facets = my_decode($io->{line}, $io->{stream})) {
            $event->{facet_data} = $facets;
            return;
        }

        # Not recognized -- fall back to raw stream capture.
        $self->SUPER::parse_stream_line($io, $event);
    }

    1;

C<normalize_event> still runs afterward, so the subclass does not need to
worry about populating the C<harness> facet.

=head1 SEE ALSO

L<Test2::Harness2::Collector> -- the collector that drives the parser.

L<Test2::Harness2::Collector::Parser::IOParser::Stream> -- TAP-aware
subclass.

L<Test2::Harness2::Event> -- the event class returned by C<parse_io>.

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
