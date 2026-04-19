package Test2::Harness2::Util::File;
use strict;
use warnings;

our $VERSION = '2.000011';

use IO::Handle;

use Test2::Harness2::Util();

use Carp qw/croak confess/;
use Fcntl qw/SEEK_SET SEEK_CUR/;

use Object::HashBase qw{ -name -_fh -_init_fh done -line_pos <skip_bad_decode };

sub exists { -e $_[0]->{+NAME} }

sub decode { shift; $_[0] }
sub encode { shift; $_[0] }

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+_INIT_FH} = delete $self->{fh};
}

sub open_file {
    my $self = shift;
    return Test2::Harness2::Util::open_file($self->{+NAME}, @_);
}

sub maybe_read {
    my $self = shift;
    return undef unless -e $self->{+NAME};
    return $self->read;
}

sub read {
    my $self = shift;
    my $out  = Test2::Harness2::Util::read_file($self->{+NAME});

    my $ok = eval { $out = $self->decode($out); 1 };
    my $err = $@;
    confess "$self->{+NAME}: $err" unless $ok;
    return $out;
}

sub rewrite {
    my $self = shift;
    return Test2::Harness2::Util::write_file($self->{+NAME}, $self->encode(@_));
}

sub write {
    my $self = shift;
    return Test2::Harness2::Util::write_file_atomic($self->{+NAME}, $self->encode(@_));
}

sub reset {
    my $self = shift;
    delete $self->{+_FH};
    delete $self->{+DONE};
    delete $self->{+LINE_POS};
    return;
}

sub fh {
    my $self = shift;
    return $self->{+_FH}->{$$} if $self->{+_FH}->{$$};

    # Remove any other PID handles
    $self->{+_FH} = {};

    if (my $fh = $self->{+_INIT_FH}) {
        $self->{+_FH}->{$$} = $fh;
    }
    else {
        $self->{+_FH}->{$$} = Test2::Harness2::Util::maybe_open_file($self->{+NAME}) or return undef;
    }

    $self->{+_FH}->{$$}->blocking(0);
    return $self->{+_FH}->{$$};
}

sub read_line {
    my $self = shift;
    my %params = @_;

    my $pos = $params{from};
    $pos = $self->{+LINE_POS} ||= 0 unless defined $pos;

    my $fh = $self->{+_FH}->{$$} || $self->fh or return undef;
    seek($fh, $pos, SEEK_SET) or die "Could not seek: $!"
        if eof($fh) || tell($fh) != $pos;

    my $line = <$fh>;

    # No line, nothing to do
    return unless defined $line && length($line);

    # Partial line, hold off unless done
    return unless $self->{+DONE} || substr($line, -1, 1) eq "\n";

    my $new_pos = tell($fh);
    die "Failed to 'tell': $!" if $new_pos == -1;

    my $err = 0;
    unless (eval { $line = $self->decode($line); 1 }) {
        $err = $@ // 'error';
        confess "$self->{+NAME} ($pos -> $new_pos): $err" unless $self->{+SKIP_BAD_DECODE};
        warn "Skipping line that failed to decode: $err\n" if $self->{+SKIP_BAD_DECODE} > 1;
        $line = undef;
    }

    $self->{+LINE_POS} = $new_pos unless defined $params{peek} || defined $params{from};
    return $line unless wantarray;
    return ($pos, $new_pos, $line, $err);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File - Utility class for manipulating a file.

=head1 DESCRIPTION

Base class for the harness's file helpers. Wraps a path in an object that can
be opened, read in full, written atomically, or iterated line-by-line. The
base class does no encoding; subclasses override C<decode>/C<encode> to layer
a format (see L<Test2::Harness2::Util::File::JSON>,
L<Test2::Harness2::Util::File::JSONL>, L<Test2::Harness2::Util::File::Value>).

=head1 SYNOPSIS

    use Test2::Harness2::Util::File;

    my $f = Test2::Harness2::Util::File->new(name => '/path/to/file');

    $f->write($content);

    my $fh = $f->open_file('<');

    # Read, throw exception if it cannot read
    my $content = $f->read();

    # Try to read, but do not throw an exception if it cannot be read.
    my $content_or_undef = $f->maybe_read();

    my $line1 = $f->read_line();
    my $line2 = $f->read_line();
    ...

=head1 ATTRIBUTES

=over 4

=item $filename = $f->name

The filename. Required at construction.

=item $bool = $f->done

True once C<read_line()> has observed every line of the file. Used in
conjunction with L</SKIP_BAD_DECODE>-style partial-line handling to
distinguish "wait for more data" from "end of file".

=item $int = $f->skip_bad_decode

When truthy, C<read_line()> tolerates decode errors on a line instead of
throwing. At C<2> or above a diagnostic is C<warn>ed for each skipped
line. At C<1> the offending line is silently dropped.

=back

=head1 METHODS

=over 4

=item $decoded = $f->decode($encoded)

Identity transform in the base class; override in subclasses that layer
a format on top of the raw bytes.

=item $encoded = $f->encode($decoded)

Identity transform in the base class; override in subclasses that layer
a format on top of the raw bytes.

=item $bool = $f->exists()

True when the file exists on disk.

=item $content_or_undef = $f->maybe_read()

Return the file's contents (the whole file as a single decoded value) or
C<undef> when the file is missing.

=item $fh = $f->open_file()

=item $fh = $f->open_file($mode)

Open the backing file. Delegates to L<Test2::Harness2::Util/open_file>,
so C<.gz>/C<.bz2> extensions are transparently decompressed on read.

=item $content = $f->read()

Return the whole file as a single decoded value. Dies if the file is
missing or cannot be decoded.

=item $line = $f->read_line()

Iterator method. Each call returns the next line (decoded) or C<undef>
at EOF. Partial lines (no terminating newline) are held back unless
C<< $self->done >> is true, so streamed writers do not produce torn
lines to readers. Call L</reset> to rewind.

=item $f->reset()

Clear the internal iteration cursor so the next C<read_line> starts
over.

=item $f->write($content)

Atomic write: serialises C<$content> via L</encode>, writes it to a
sibling C<.pend> file, and C<rename>s it over the target under a
signal mask. Readers never observe a partial file.

=item $f->rewrite($content)

Non-atomic write: opens the file in C<< '>' >> mode and overwrites it.
Prefer L</write> unless you explicitly need to avoid the rename.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
