package Test2::Harness::Util::File::Stream;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak/;
use Test2::Harness::Util qw/lock_file unlock_file/;
use Fcntl qw/SEEK_SET/;

use parent 'Test2::Harness::Util::File';
use Test2::Harness::Util::HashBase qw/use_write_lock -tail/;

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
    my $self = shift;
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
    my $self = shift;
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
        $fh = Test2::Harness::Util::open_file($self->name, '>>');
    }

    $fh->autoflush(1);
    seek($fh,2,0);
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

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File::Stream - Utility class for manipulating a file that
serves as an output stream.

=head1 DESCRIPTION

Subclass of L<Test2::Harness::File> that streams the contents of a file, even
if the file is still being written.

=head1 SYNOPSIS

    use Test2::Harness::Util::File::Stream;

    my $stream = Test2::Harness::Util::File::Stream->new(name => 'path/to/file');

    # Read some lines
    my @lines = $stream->poll;

    ...

    # Read more lines, if any.
    push @lines => $stream->poll;

=head1 ATTRIBUTES

See L<Test2::Harness::File> for additional attributes.

These can be passed in as construction arguments if desired.

=over 4

=item $bool = $stream->use_write_lock

=item $stream->use_write_lock($bool)

Lock the file for every C<write()> operation.

=item $bool = $stream->tail

Start near the end of the file and only poll for updates appended to it.

=back

=head1 METHODS

See L<Test2::Harness::File> for additional methods.

=over 4

=item @lines = $stream->read()

Read all lines from the beginning. Every time it is called it returns ALL lines.

=item @lines = $stream->poll()

=item @lines = $stream->poll(max => $int)

Poll for lines. This is an iterator, it should not return the same line more
than once, you can call it multiple times to get any additional lines that have
been added since the last poll.

=item $stream->write(@content)

Append @content to the file.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
