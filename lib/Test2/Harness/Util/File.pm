package Test2::Harness::Util::File;
use strict;
use warnings;

our $VERSION = '0.001077';

use IO::Handle;

use Test2::Harness::Util();

use Carp qw/croak confess/;
use Fcntl qw/SEEK_SET SEEK_CUR/;

use Test2::Harness::Util::HashBase qw{ -name -_fh -_init_fh done -stamped -line_pos };

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

    eval { $line = $self->decode($line); 1 } or confess "$self->{+NAME} ($pos -> $new_pos): $@";

    $self->{+LINE_POS} = $new_pos unless defined $params{peek} || defined $params{from};
    return ($pos, $new_pos, $line);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::File - Utility class for manipulating a file.

=head1 DESCRIPTION

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

Copyright 2017 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
