package Test2::Harness2::Util::JSONL::Reader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Fcntl qw/SEEK_SET/;

use Test2::Harness2::Util::JSON qw/decode_json/;

# Tail-style reader for a JSONL file, plain or zstd-framed. Holds the
# state needed to drain newly-arrived records since the previous
# call: a byte position for the plain form, or a long-lived
# Test2::Harness2::Util::Zstd::Reader for the zstd form.
#
# Both modes return decoded JSON records via L</read_lines> (drain) or
# L</readline> (one). Used as the FileMonitor delegate for the JSONL
# collector logger.

sub new {
    my ($class, %opts) = @_;
    my $path = delete $opts{path} // delete $opts{name};
    croak "path is required" unless defined $path;

    my $self = bless {
        path   => $path,
        buffer => [],
    } => $class;

    if ($path =~ /\.zst\z/) {
        require Test2::Harness2::Util::Zstd;
        $self->{zstd} = 1;
    }
    else {
        $self->{zstd} = 0;
        $self->{pos}  = 0;
    }

    return $self;
}

sub _ensure_reader {
    my $self = shift;

    if ($self->{zstd}) {
        return $self->{reader} if $self->{reader};
        return undef unless -e $self->{path};
        $self->{reader} = Test2::Harness2::Util::Zstd::open_zstd_reader($self->{path});
        return $self->{reader};
    }

    return $self->{fh} if $self->{fh};
    return undef unless -e $self->{path};

    open(my $fh, '<', $self->{path}) or croak "open '$self->{path}': $!";
    binmode $fh;
    $self->{fh} = $fh;
    return $fh;
}

sub _drain {
    my $self = shift;

    if ($self->{zstd}) {
        my $reader = $self->_ensure_reader or return;
        while (defined(my $payload = $reader->readline)) {
            my $decoded;
            my $ok  = eval { $decoded = decode_json($payload); 1 };
            my $err = $@;
            unless ($ok) {
                warn "Skipping zstd JSONL frame that failed to decode in '$self->{path}': $err";
                next;
            }
            push @{$self->{buffer}} => $decoded;
        }
        return;
    }

    my $fh = $self->_ensure_reader or return;

    seek($fh, $self->{pos}, SEEK_SET) or return;

    while (defined(my $line = <$fh>)) {
        # Hold back a torn final line until the writer finishes it.
        if (substr($line, -1, 1) ne "\n") {
            seek($fh, $self->{pos}, SEEK_SET);
            last;
        }
        $self->{pos} = tell($fh);
        my $decoded;
        my $ok  = eval { $decoded = decode_json($line); 1 };
        my $err = $@;
        unless ($ok) {
            warn "Skipping JSONL line that failed to decode in '$self->{path}': $err";
            next;
        }
        push @{$self->{buffer}} => $decoded;
    }

    return;
}

sub read_lines {
    my $self = shift;

    $self->_drain;

    my @out = @{$self->{buffer}};
    $self->{buffer} = [];
    return @out;
}

sub readline {
    my $self = shift;

    $self->_drain unless @{$self->{buffer}};
    return undef unless @{$self->{buffer}};
    return shift @{$self->{buffer}};
}

sub exists { -e $_[0]->{path} }

sub close {
    my $self = shift;

    if (my $reader = delete $self->{reader}) {
        $reader->close;
    }
    if (my $fh = delete $self->{fh}) {
        return close($fh);
    }
    return 1;
}

sub DESTROY {
    my $self = shift;
    $self->close if $self->{fh} || $self->{reader};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::JSONL::Reader - Tail-style JSONL reader (plain or zstd-framed).

=head1 SYNOPSIS

    use Test2::Harness2::Util::JSONL::Reader;
    use Test2::Harness2::Util::FileMonitor;

    my $delegate = Test2::Harness2::Util::JSONL::Reader->new(path => $path);
    my $monitor = Test2::Harness2::Util::FileMonitor->new(
        file     => $path,
        delegate => $delegate,
    );

    while (my $delegate = $monitor->changed) {
        my @items = $delegate->read_lines;
        ... handle decoded items ...
    }

=head1 DESCRIPTION

Tail-style reader that drains newly-arrived JSONL records since the
previous call. Auto-detects the on-disk format from the path suffix:
C<.zst> uses L<Test2::Harness2::Util::Zstd::Reader>, anything else
uses a plain newline-delimited byte-position reader. Both modes
return decoded JSON records, so the consumer sees a single uniform
interface.

Used as the FileMonitor delegate for the JSONL collector logger.

=head1 METHODS

=over 4

=item @items = $r->read_lines

Drain every record that has arrived since the previous call. Decoded
JSON records are returned as a list. Torn / partial input is held
back.

=item $item = $r->readline

Return one decoded record or C<undef> when none is buffered.

=item $bool = $r->exists

True when the underlying path exists. Useful for matching the
"reader is held open across an as-yet-uncreated path" pattern the
streamer uses.

=item $r->close

Close the underlying file handle / zstd reader. Called automatically
on C<DESTROY>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::Zstd::Reader> -- zstd-framed primitive used
internally for C<.zst> paths.

L<Test2::Harness2::Util::FileMonitor> -- change-detection driver.

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
