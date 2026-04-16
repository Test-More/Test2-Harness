package Test2::Harness2::Collector::Parser::IOParser::Stream;
use strict;
use warnings;

our $VERSION = '2.000011';

use Test2::Harness2::Collector::Parser::TapParser qw/parse_stdout_tap parse_stderr_tap/;

use parent 'Test2::Harness2::Collector::Parser::IOParser';
use Object::HashBase qw{};

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream = $io->{stream};
    my $text   = $io->{line};

    my $facets = $stream eq 'stdout' ? parse_stdout_tap($text) : parse_stderr_tap($text);

    if ($facets) {
        $event->{facet_data} = $facets;
        return;
    }

    $self->SUPER::parse_stream_line($io, $event);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Parser::IOParser::Stream - TAP-aware IOParser for stdout/stderr.

=head1 DESCRIPTION

A drop-in replacement for L<Test2::Harness2::Collector::Parser::IOParser> that
understands TAP on top of the raw line-capture behavior of its parent. For
each line read from the collected process this parser tries to interpret it
as TAP using L<Test2::Harness2::Collector::Parser::TapParser>. When the line
parses as TAP the event's facet data is replaced with the parsed facets
(plan, assert, info, control, etc.). When it does not, the line is treated
as ordinary stream output and a C<from_stream> facet is emitted exactly as
the base IOParser would produce.

STDOUT and STDERR are handled with different TAP rules:

=over 4

=item STDOUT

Any recognized TAP construct is parsed: plans, assertions (with
TODO/SKIP directives), buffered subtest open/close, comments (treated as
C<NOTE>), C<Bail out!>, and C<TAP version>.

=item STDERR

Only comment lines (C</^\s*#/>) are parsed, and they become C<DIAG>
entries. Any other STDERR line falls through to the plain IOParser
C<from_stream> path, which tags the line C<STDERR> and marks it as debug.

=back

For any line that is recognized as TAP, a C<from_tap> facet is attached
recording the source stream (C<STDOUT> or C<STDERR>) and the original line
verbatim. No C<from_stream> facet is attached in that case; the two are
mutually exclusive per event.

In either path the base class C<normalize_event> step still runs, so every
event ends up with a populated C<harness> facet (C<event_id>, C<stamp>, and
optionally C<run_id>/C<job_id>/C<job_try> if the parser was constructed with
those attributes).

=head1 USAGE

Pass the class name or an instance to L<Test2::Harness2::Collector>'s
C<parser> attribute:

    use Test2::Harness2::Collector;

    # By class name -- the collector will instantiate it.
    my $c = Test2::Harness2::Collector->spawn(
        launch  => ['perl', 'some_test.t'],
        parser  => 'Test2::Harness2::Collector::Parser::IOParser::Stream',
        loggers => [
            ['Test2::Harness2::Collector::Logger::JSONL',
                output_file => 'events.jsonl'],
        ],
    );

    # Or with explicit attributes so events carry run/job identifiers.
    use Test2::Harness2::Collector::Parser::IOParser::Stream;

    my $parser = Test2::Harness2::Collector::Parser::IOParser::Stream->new(
        run_id  => $run_id,
        job_id  => $job_id,
        job_try => 1,
    );

    my $c = Test2::Harness2::Collector->spawn(
        launch => ['perl', 'some_test.t'],
        parser => $parser,
        # ... loggers, etc.
    );

=head1 ATTRIBUTES

Inherited from L<Test2::Harness2::Collector::Parser::IOParser>:

=over 4

=item run_id, job_id, job_try

Optional identifiers copied into the C<harness> facet of every event.

=item name, type

Optional metadata slots reserved for caller-specific use.

=back

=head1 METHODS

=over 4

=item $parser->parse_stream_line(\%io, $event)

Overridden. Called by the inherited C<parse_io> with a hashref of the input
parameters (C<stream>, C<line>, optional C<stamp> / C<event_id>) and the
event being built. Tries TAP first; on a hit, replaces C<< $event->{facet_data} >>
with the parsed facets and returns. On a miss, delegates to the base class's
C<parse_stream_line> which produces the plain C<from_stream> / C<info>
facets.

This method is not typically invoked directly; use C<parse_io> from the base
class instead.

=back

=head1 SEE ALSO

L<Test2::Harness2::Collector::Parser::IOParser> -- base class, handles the
raw C<from_stream> fallback and C<harness> normalization.

L<Test2::Harness2::Collector::Parser::TapParser> -- the underlying TAP
recognizer; its documentation describes exactly which lines are matched and
what facets they produce.

L<Test2::Harness2::Collector> -- the collector that drives the parser.

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
