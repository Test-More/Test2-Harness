package Test2::Formatter::Stream2::IOEvents::Tie;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use IO::Handle ();

use Object::HashBase qw{
    <name
    <real_fh
    <fd
    <pid
    active
    pending
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::Stream2::IOEvents::Tie - Tie handler that turns prints to a
standard handle into Test2 events while a subtest is running.

=head1 DESCRIPTION

The tie handler installed on C<STDOUT> / C<STDERR> by
L<Test2::Formatter::Stream2::IOEvents>. Each print is converted into a Test2
C<info> event -- so it folds into the running subtest at the correct nesting --
B<only> while a subtest is open. Outside a subtest (and in any situation where
calling into the Test2 API would be unsafe) the print passes straight through to
the real handle.

The object is normally built by C<TIEHANDLE> via C<tie>, but L</_build> can
construct one directly (without tie()ing a glob) for testing the conversion
guard.

=head1 ATTRIBUTES

=over 4

=item name

C<'STDOUT'> or C<'STDERR'> -- which handle this tie stands in for.

=item real_fh

A dup of the original handle, used for passthrough writes.

=item fd

The original handle's file descriptor number, returned by L</FILENO> so
C<fileno()> / C<-t> see the real descriptor.

=item pid

The pid that built the tie. A print from a different pid (a fork) passes
through rather than risking a Test2 context in a child.

=item active

Reentrancy latch: set while a conversion is in progress so output produced
during event emission cannot recurse back into conversion.

=item pending

True when this handle has an unterminated (no trailing newline) line
outstanding on the real channel. While set, even newline-terminated prints pass
through, so the partial line is completed on the same channel rather than split
between the raw stream and an event. Per handle -- a partial on STDERR does not
affect STDOUT.

=back

=cut

=head1 TIE METHODS

=cut

=over 4

=item $tie = $class->TIEHANDLE($name)

Standard C<tie> constructor; delegates to L</_build>.

=item $self->PRINT(@args)

=item $self->PRINTF($format, @args)

Route the output through L</_route>: a whole, newline-terminated line with no
partial line outstanding on this handle becomes a Test2 C<info> event;
everything else passes through to the real handle. C<PRINT> joins C<@args> with
C<$,> and appends C<$\> (matching C<print>); C<PRINTF> applies C<sprintf> first.

=item FILENO

=item $fd = $self->FILENO

The real descriptor number, so C<fileno()> and C<-t> report on the underlying
handle rather than the tie.

=item $self->WRITE($buf, $len, $offset)

C<syswrite> straight to the real handle -- byte-level writes are never converted
to events.

=item $self->BINMODE($layer)

Apply a layer (or the default) to the real handle.

=item $self->OPEN($mode, @args)

=item $self->CLOSE

Untie the standard handle, then re-C<open> / C<close> it, so a test that
redirects or closes C<STDOUT> / C<STDERR> gets the real handle back.

=item $self->autoflush($bool)

Proxy autoflush to the real handle.

=back

=cut

sub TIEHANDLE ($class, $name) { return $class->_build($name) }

sub PRINT ($self, @args) {
    my $sep  = defined($,) ? $,         : '';
    my $text = join($sep, @args);
    $text .= $\ if defined $\;
    return $self->_route($text);
}

sub PRINTF ($self, $format, @args) {
    return $self->_route(sprintf($format, @args));
}

sub FILENO ($self) { return $self->{+FD} }

sub WRITE ($self, $buf, $len = undef, $offset = undef) {
    my $fh = $self->{+REAL_FH};
    return syswrite($fh, $buf)                 unless defined $len;
    return syswrite($fh, $buf, $len)           unless defined $offset;
    return syswrite($fh, $buf, $len, $offset);
}

sub BINMODE ($self, $layer = undef) {
    my $fh = $self->{+REAL_FH};
    return defined($layer) ? binmode($fh, $layer) : binmode($fh);
}

sub OPEN ($self, $mode, @args) {
    my $glob = $self->{+NAME} eq 'STDOUT' ? \*STDOUT : \*STDERR;
    untie(*$glob);
    return @args ? open($glob, $mode, @args) : open($glob, $mode);
}

sub CLOSE ($self) {
    my $glob = $self->{+NAME} eq 'STDOUT' ? \*STDOUT : \*STDERR;
    untie(*$glob);
    return close($glob);
}

sub autoflush ($self, @args) {
    my $fh = $self->{+REAL_FH};
    return $fh->autoflush(@args);
}

=head1 PRIVATE METHODS

=cut

=over 4

=item _route

=item $self->_route($text)

Decide what to do with one print's worth of C<$text>. Convert it to an event
only when it ends in a newline, no partial line is outstanding on this handle
(L</pending>), and L</_should_convert> agrees. Otherwise pass it through and
update L</pending> to follow the real channel: cleared when C<$text> ends a
line, set when it leaves one open. Empty text is a no-op.

=item $self->_passthrough(@args)

Write C<@args> to the real handle with ordinary C<print> semantics.

=item $self->_emit($text)

Send C<$text> as a Test2 C<info> event (tagged with the handle name, C<debug>
for STDERR) through a fresh context, latching L</active> so output produced
during emission cannot recurse. The single trailing newline is chomped (the
event holds the line, not its terminator); interior newlines are kept. A no-op
for empty text.

=item _build

=item $tie = $class->_build($name)

Construct a handler for C<$name> ('STDOUT' or 'STDERR'), capturing a dup of the
real handle and the current pid. Does not C<tie> anything.

=item _should_convert

=item $bool = $self->_should_convert

True when a print should become a Test2 event rather than pass through: a
subtest is open, the Test2 API is loaded and running, this is the original
process, and no conversion is already in progress.

=back

=cut

sub _build ($class, $name) {
    croak "name must be STDOUT or STDERR, not '$name'"
        unless $name eq 'STDOUT' || $name eq 'STDERR';

    my $glob = $name eq 'STDOUT' ? \*STDOUT : \*STDERR;
    open(my $real_fh, '>&', $glob) or croak "dup $name: $!";

    # Unbuffered, like the handle it stands in for (Stream2 autoflushes
    # STDOUT/STDERR). Otherwise passthrough output buffered here is lost when a
    # test exits hard (e.g. POSIX::_exit) before Perl flushes.
    $real_fh->autoflush(1);

    # NB: HashBase constants only evaluate inside {} subscripts, not before a
    # fat comma -- build the object with subscript assignments, not a literal.
    my $self = bless {}, $class;
    $self->{+NAME}    = $name;
    $self->{+REAL_FH} = $real_fh;
    $self->{+FD}      = CORE::fileno($glob);
    $self->{+PID}     = $$;
    $self->{+ACTIVE}  = 0;
    $self->{+PENDING} = 0;

    return $self;
}

sub _route ($self, $text) {
    return 1 unless length $text;

    my $terminated = $text =~ /\n\z/ ? 1 : 0;

    # Convert only a whole line that has no partial line outstanding before it.
    # Emitting leaves the real channel untouched, so the pending state is
    # unchanged (it was already clear).
    return $self->_emit($text)
        if $terminated && !$self->{+PENDING} && $self->_should_convert;

    # Passthrough: the real channel now holds a complete line (terminated) or a
    # still-open partial (not), so track that for the next print on this handle.
    $self->{+PENDING} = $terminated ? 0 : 1;
    return $self->_passthrough($text);
}

sub _passthrough ($self, @args) {
    my $fh = $self->{+REAL_FH};
    return print {$fh} @args;
}

sub _emit ($self, $text) {
    return 1 unless length $text;

    # The event carries the line, not the line terminator: drop the single
    # trailing newline (the one that made this a whole line). Interior newlines
    # in a multi-line print are kept.
    chomp $text;

    local $self->{+ACTIVE} = 1;

    my $ctx = Test2::API::context();
    $ctx->send_ev2_and_release(
        info => [
            {
                tag     => $self->{+NAME},
                details => $text,
                ($self->{+NAME} eq 'STDERR' ? (debug => 1) : ()),
            },
        ],
    );

    return 1;
}

sub _should_convert ($self) {
    return 0 if $self->{+ACTIVE};
    return 0 unless $INC{'Test2/API.pm'};
    return 0 unless ${^GLOBAL_PHASE} eq 'RUN';
    return 0 if $self->{+PID} != $$;

    my $top = Test2::API::test2_stack()->top;
    return 0 unless $top && $top->nested;

    return 1;
}

1;

__END__

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
