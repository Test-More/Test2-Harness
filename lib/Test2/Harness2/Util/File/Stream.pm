package Test2::Harness2::Util::File::Stream;
use strict;
use warnings;

# Probably best to get rid of this class as we will be removing the Zstd subclass in favor of the reader, writer, and FileMonitor classes. The JSONL class can be reworked.

our $VERSION = '2.000011';

use Carp qw/croak/;
use Test2::Harness2::Util qw/lock_file unlock_file/;
use Fcntl qw/SEEK_SET/;

use parent 'Test2::Harness2::Util::File';
use Object::HashBase qw/use_write_lock -tail/;

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $tail = $self->{+TAIL} or return;

    return unless $self->exists;

    my @lines = $self->poll_with_index;
    if (@lines < $self->{+TAIL}) {
        $self->seek(0);
    }
    else {
        $self->seek($lines[0 - $tail]->[0]);
    }
}

sub poll_with_index {
    my $self   = shift;
    my %params = @_;

    my $max = delete $params{max} || 0;

    my $pos = $params{from};
    $pos = $self->{+LINE_POS} ||= 0 unless defined $pos;

    my @out;
    while (!$max || @out < $max) {
        my ($spos, $epos, $line, $err) = $self->read_line(%params, from => $pos);
        last unless defined($line) || defined($spos) || defined($epos) || $err;

        $self->{+LINE_POS} = $epos unless $params{peek} || defined $params{from};
        push @out => [$spos, $epos, $line] unless $err;
        $pos = $epos;
    }

    return @out;
}

sub read {
    my $self = shift;

    return $self->poll(from => 0);
}

sub poll {
    my $self  = shift;
    my @lines = $self->poll_with_index(@_);
    return map { $_->[-1] } @lines;
}

sub write {
    my $self = shift;

    my $name = $self->{+NAME};

    my $fh;
    if ($self->{+USE_WRITE_LOCK}) {
        $fh = lock_file($self->name, '>>');
    }
    else {
        $fh = Test2::Harness2::Util::open_file($self->name, '>>');
    }

    $fh->autoflush(1);
    seek($fh, 2, 0);
    print {$fh} $self->encode($_) for @_;

    unlock_file($fh) if $self->{+USE_WRITE_LOCK};

    close($fh) or die "Could not close file '$name': $!";

    return @_;
}

sub seek {
    my $self = shift;
    my ($pos) = @_;

    my $fh   = $self->fh;
    my $name = $self->{+NAME};

    seek($fh, $pos, SEEK_SET) or die "Could not seek to position $pos in file '$name': $!";
    $self->{+LINE_POS} = $pos;
}

# Block until new lines have been appended to the file or $timeout
# seconds elapse. Layers on wait_for_change() from the base class:
# Linux::Inotify2 when available, falling back to a Time::HiRes
# polling loop. Returns 1 if new data (past the current read
# cursor) is likely available; 0 if the timeout fired.
#
# "Likely" because wait_for_change reports any change -- a
# truncate, an attribute touch, an atomic rename. Callers that
# tolerate spurious wake-ups (the usual "poll() returns nothing
# this round" idiom) get the cheap wait. Callers that need a strict
# guarantee can re-run poll() after the wake and retry if it returns
# empty.
sub wait_for_data {
    my $self = shift;
    my ($timeout) = @_;
    return $self->wait_for_change($timeout);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::Stream - File helper for append-only log streams.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File> that streams the contents of a file
even while it is still being written. Each C<poll()> returns any lines that
have arrived since the last call, without re-reading earlier ones.

=head1 SYNOPSIS

    use Test2::Harness2::Util::File::Stream;

    my $stream = Test2::Harness2::Util::File::Stream->new(name => 'path/to/file');

    # Read some lines
    my @lines = $stream->poll;

    ...

    # Read more lines, if any.
    push @lines => $stream->poll;

=head1 ATTRIBUTES

See L<Test2::Harness2::Util::File> for additional attributes.

=over 4

=item $bool = $stream->use_write_lock

=item $stream->use_write_lock($bool)

Lock the file for every C<write()> operation.

=item $bool = $stream->tail

Start near the end of the file and only poll for updates appended to it.
When fewer than C<$tail> lines exist the stream starts at the beginning
so callers do not lose history.

=back

=head1 METHODS

=over 4

=item @lines = $stream->read()

Read all lines from the beginning and return them. Every call returns
all lines currently in the file; use L</poll> for iteration.

=item @lines = $stream->poll()

=item @lines = $stream->poll(max => $int)

Iterator. Returns any lines that have arrived since the previous call
(starting from the construction-time cursor or the last C<seek>). Pass
C<max> to cap the number of lines returned in one call.

=item @rows = $stream->poll_with_index(...)

Same as L</poll> but each row is an arrayref of
C<< [start_pos, end_pos, decoded_line] >> so callers can use the byte
offsets for seek/resume.

=item $stream->seek($pos)

Reposition the read cursor to C<$pos> (byte offset from the start of the
file).

=item $stream->write(@content)

Append C<@content> to the file. Each element is passed through
L<Test2::Harness2::Util::File/encode>. If C<use_write_lock> is set, the
write is serialised under C<flock>.

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
