package Test2::Harness2::Util::File::JSONL::Zstd;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak confess/;

use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer open_zstd_reader/;

use parent 'Test2::Harness2::Util::File::JSONL';
use Object::HashBase qw/<dict_path +_reader +_reader_pos +_peeked/;

# JSONL file with zstd-compressed frames on disk -- one frame per line.
# Inherits the encode/decode JSON-line helpers from Util::File::JSONL,
# but overrides every method that depends on raw byte offsets in the
# parent (Util::File::Stream uses tell/seek). Compressed bytes do not
# correspond to line boundaries, so we keep our own decoded line
# position alongside a long-lived zstd reader.

sub init {
    my $self = shift;
    $self->SUPER::init();
    $self->{+_READER_POS} = 0;
    $self->{+_PEEKED}     = [];
}

sub _reader {
    my $self = shift;
    return $self->{+_READER} if $self->{+_READER};
    return undef unless -e $self->{+NAME};
    $self->{+_READER} = open_zstd_reader(
        $self->{+NAME},
        ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
    );
    return $self->{+_READER};
}

# Append a single jsonl line as one zstd frame. Each call writes one
# self-contained frame, atomic-appended to the file via syswrite.
sub write {
    my $self = shift;

    my $writer = open_zstd_writer(
        $self->{+NAME},
        ($self->{+DICT_PATH} ? (dict_path => $self->{+DICT_PATH}) : ()),
    );
    for my $entry (@_) {
        # Bare json -- zstd frames self-delimit, and the inherited
        # encode() would append a "\n" that has no separator role
        # under the framed format. The extract command is
        # responsible for inserting newlines when producing
        # extracted plaintext jsonl.
        $writer->print(encode_json($entry));
    }
    $writer->close;

    return @_;
}

# poll_with_index returns one [start, end, decoded_line] tuple per
# decoded line read out of the underlying zstd-framed file. The
# offsets are decoded-line offsets, not raw file offsets, but they
# preserve the contract used by Util::File::Stream consumers (tail
# resume, peek, max-N reads).
sub poll_with_index {
    my $self   = shift;
    my %params = @_;

    my $max  = delete $params{max}  || 0;
    my $peek = delete $params{peek} || 0;

    my @out;

    # Drain any rows previously buffered by a peek call. They count
    # against $max and become consumed (vanish from the buffer)
    # unless this call is itself a peek -- in which case they stay
    # at the head of the queue for the next call.
    my $buffer = $self->{+_PEEKED} ||= [];
    while (@$buffer && (!$max || @out < $max)) {
        push @out => $buffer->[0];
        if (!$peek) {
            shift @$buffer;
            $self->{+_READER_POS} = $out[-1]->[1];
        }
        else {
            # Walk the buffer rather than draining it.
            last if @out == @$buffer;
        }
    }

    return @out if $max && @out >= $max;

    my $reader = $self->_reader;
    return @out unless $reader;

    my $pos = $self->{+_READER_POS};

    while (!$max || @out < $max) {
        my $line = $reader->readline;
        last unless defined $line;
        last unless length $line;

        my $start = $pos;
        my $end   = $pos + length $line;
        $pos = $end;

        my $decoded;
        my $ok  = eval { $decoded = $self->decode($line); 1 };
        my $err = $@;
        unless ($ok) {
            confess "$self->{+NAME} ($start -> $end): $err"
                unless $self->{+SKIP_BAD_DECODE};
            warn "Skipping line that failed to decode: $err\n"
                if $self->{+SKIP_BAD_DECODE} > 1;
            next;
        }

        my $row = [$start, $end, $decoded];
        push @out     => $row;
        push @$buffer => $row if $peek;
    }

    $self->{+_READER_POS} = $pos unless $peek;
    return @out;
}

sub poll {
    my $self  = shift;
    my @lines = $self->poll_with_index(@_);
    return map { $_->[-1] } @lines;
}

sub read {
    my $self = shift;
    return $self->poll(from => 0);
}

sub reset {
    my $self = shift;
    delete $self->{+_READER};
    $self->{+_READER_POS} = 0;
    return;
}

# Stream's read_line / seek do not work on a compressed file: byte
# offsets in the file do not correspond to jsonl line starts. Disable
# them rather than silently misbehave.
sub read_line { croak "read_line is not supported on a zstd-framed jsonl file" }
sub seek      { croak "seek is not supported on a zstd-framed jsonl file" }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::JSONL::Zstd - JSONL file with zstd compression on disk (one frame per line, append-safe).

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File::JSONL> for the
C<.jsonl.zst> log files yath produces under C<workdir/logs/>.

Each line is stored as a single self-contained zstd frame appended
to the underlying file. Concurrent writers are safe as long as a
frame fits in C<PIPE_BUF> (4 KiB on Linux); the per-line jsonl
events the harness emits stay well below that.

The reader uses L<Test2::Harness2::Util::Zstd>'s long-lived
C<open_zstd_reader> handle internally, so tailing across appended
frames works the same as the plaintext sibling -- C<poll> returns
new lines as they land.

=head1 ATTRIBUTES

=over 4

=item dict_path

Optional. When set, every read and write uses the dictionary at the
given path. When unset, dict-less compression is used.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::File::JSONL> -- plaintext sibling, used for
extracted (post-C<yath extract>) jsonl files.

L<Test2::Harness2::Util::Zstd> -- shared zstd helper.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
