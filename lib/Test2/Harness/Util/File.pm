package Test2::Harness::Util::File;
use strict;
use warnings;

our $VERSION = '1.000155';

use IO::Handle;

use Test2::Harness::Util();

use Carp qw/croak confess/;
use Fcntl qw/SEEK_SET SEEK_CUR/;

use Test2::Harness::Util::HashBase qw{ -name -_fh -_init_fh done -line_pos <skip_bad_decode };

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
    return Test2::Harness::Util::open_file($self->{+NAME}, @_)
}

sub maybe_read {
    my $self = shift;
    return undef unless -e $self->{+NAME};
    return $self->read;
}

sub read {
    my $self = shift;
    my $out = Test2::Harness::Util::read_file($self->{+NAME});

    eval { $out = $self->decode($out); 1 } or confess "$self->{+NAME}: $@";
    return $out;
}

sub rewrite {
    my $self = shift;
    return Test2::Harness::Util::write_file($self->{+NAME}, $self->encode(@_));
}

sub write {
    my $self = shift;
    return Test2::Harness::Util::write_file_atomic($self->{+NAME}, $self->encode(@_));
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
        $self->{+_FH}->{$$} = Test2::Harness::Util::maybe_open_file($self->{+NAME}) or return undef;
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
    seek($fh,$pos,SEEK_SET) or die "Could not seek: $!"
        if eof($fh) || tell($fh) != $pos;

    my $line = <$fh>;

    # No line, nothing to do
    return unless defined $line && length($line);

    # Partial line, hold off unless done
    return unless $self->{+DONE} || substr($line, -1, 1) eq "\n";

    my $new_pos = tell($fh);
    die "Failed to 'tell': $!" if $new_pos == -1;

    my $err = 0;
    local $@;
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

Test2::Harness::Util::File - Utility class for manipulating a file.

=head1 DESCRIPTION

This is a utility class for file operations. This also serves as a base class
for several file helpers.

=head1 SYNOPSIS

    use Test2::Harness::Util::File;

    my $f = Test2::Harness::Util::File->new(name => '/path/to/file');

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

=item $filename = $f->name;

Get the filename. Must also be provided during construction.

=item $bool = $f->done;

True if read_line() has read every line.

=back

=head1 METHODS

=over 4

=item $decoded = $f->decode($encoded)

This is a no-op, it returns the argument unchanged. This is called by C<read>
and C<read_line>. Subclasses can override this if the file contains encoded
data.

=item $encoded = $f->encode($decoded)

This is a no-op, it returns the argument unchanged. This is called by C<write>.
Subclasses can override this if the file contains encoded data.

=item $bool = $f->exists()

Check if the file exists

=item $content = $f->maybe_read()

This will read the file if it can and return the content (all lines joined
together as a single string). If the file cannot be read, or does not exist
this will return undef.

=item $fh = $f->open_file()

=item $fh = $f->open_file($mode)

Open a handle to the file. If no $mode is provided C<< '<' >> is used.

=item $content = $f->read()

This will read the file if it can and return the content (all lines joined
together as a single string). If the file cannot be read, or does not exist
this will throw an exception.

=item $line = $f->read_line()

Read a single line from the file, subsequent calls will read the next line and
so on until the end of the file is reached. Reset with the C<reset()> method.

=item $f->reset()

Reset the internal line iterator used by C<read_line()>.

=item $f->write($content)

This is an atomic-write. First $content will be written to a temporary file
using C<< '>' >> mode. Then the temporary file will be renamed to the desired
file name. Under the hood this uses C<write_file_atomic()> from
L<Test2::Harness::Util>.

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
