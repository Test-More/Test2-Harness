package Test2::Harness2::Util::File::JSONL;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Test2::Harness2::Util();
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use parent 'Test2::Harness2::Util::File::JSON';
use Object::HashBase;

sub decode { shift; decode_json($_[0]) }
sub encode { shift; encode_json(@_) . "\n" }

sub read {
    my $self = shift;

    return () unless -e $self->{+NAME};

    my $bytes = Test2::Harness2::Util::read_file($self->{+NAME});
    return () unless defined $bytes && length $bytes;

    my @out;
    for my $line (split /\n/, $bytes) {
        next unless length $line;
        push @out => decode_json($line);
    }
    return @out;
}

sub read_line {
    my $self = shift;
    my ($line) = @_;
    croak "read_line requires the line text" unless defined $line;
    return decode_json($line);
}

sub write {
    my $self = shift;

    my $payload = join '' => map { encode_json($_) . "\n" } @_;
    return Test2::Harness2::Util::write_file_atomic($self->{+NAME}, $payload);
}

sub rewrite {
    my $self = shift;

    my $payload = join '' => map { encode_json($_) . "\n" } @_;
    return Test2::Harness2::Util::write_file($self->{+NAME}, $payload);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::File::JSONL - Whole-file utility class for a JSONL file.

=head1 DESCRIPTION

Subclass of L<Test2::Harness2::Util::File::JSON> that treats the
backing path as a complete (not still-being-written) JSONL file.
C<read> returns the full list of decoded items, one per line; C<write>
and C<rewrite> take a list of items and encode each one with a
trailing newline.

For incremental log readers (tail-style consumption of a file that is
still being appended to), use L<Test2::Harness2::Util::JSONL::Reader>
together with L<Test2::Harness2::Util::FileMonitor>; this class is
not safe for concurrent reader/writer access.

=head1 SYNOPSIS

    use Test2::Harness2::Util::File::JSONL;

    my $jsonl = Test2::Harness2::Util::File::JSONL->new(name => '/path/to/file.jsonl');

    my @items = $jsonl->read;
    $jsonl->write({a => 1}, {b => 2});

=head1 METHODS

=over 4

=item @items = $jsonl->read

Read the file and return every line decoded as a Perl data structure.
Empty lines are skipped.

=item $item = $jsonl->read_line($line_text)

Decode a single JSONL line (the raw newline-terminated or naked text).
Convenience wrapper for callers that drive the file handle themselves.

=item $jsonl->write(@items)

Atomic write: every item is JSON-encoded with a trailing newline,
joined, and written through L<Test2::Harness2::Util/write_file_atomic>.

=item $jsonl->rewrite(@items)

Non-atomic in-place write. Same encoding rules as L</write>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::File::JSON> -- single-document JSON sibling.

L<Test2::Harness2::Util::JSONL::Reader> -- tail-style streaming reader
for live log files.

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
