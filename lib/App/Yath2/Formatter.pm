package App::Yath2::Formatter;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <settings
};

# Return true if the bytes produced by this formatter are safe to
# persist as a log artifact (i.e. they do not embed run-specific
# settings or terminal escape codes that would make them unreadable
# outside the original run context). Subclasses that embed such
# settings must override this to return 0.
sub produces_artifact { 1 }

# Convert a single event item to a byte string. Subclasses must
# override this method; the default croaks so that omissions are
# caught at test time rather than silently producing empty output.
sub convert_item { croak ref($_[0]) . " must implement convert_item" }

# Format and emit (or return) a single event item.
#
# Without out_fh: returns the formatted byte string.
# With out_fh:    prints to the filehandle and returns nothing.
sub append {
    my ($self, $item, %opts) = @_;
    my $bytes = $self->convert_item($item);
    if (my $fh = $opts{out_fh}) {
        print {$fh} $bytes;
        return;
    }
    return $bytes;
}

# Format and emit (or return) a list of event items.
#
# Without out_fh: concatenates and returns all formatted bytes.
# With out_fh:    prints everything to the filehandle and returns nothing.
sub convert {
    my ($self, $items, %opts) = @_;
    my $out = '';
    $out .= $self->convert_item($_) for @$items;
    if (my $fh = $opts{out_fh}) {
        print {$fh} $out;
        return;
    }
    return $out;
}

# Read a JSONL stream from in_fh, decode each line, format it, and
# write the result to out_fh. Both filehandle arguments are required.
# Blank lines are skipped. Decode failures are fatal.
sub feed {
    my ($self, %opts) = @_;
    my $in  = $opts{in_fh}  or croak "in_fh required";
    my $out = $opts{out_fh} or croak "out_fh required";
    while (my $line = <$in>) {
        chomp $line;
        next unless length $line;
        my $item;
        my $ok  = eval { $item = decode_json($line); 1 };
        my $err = $@;
        die "Failed to decode JSONL line: $err" unless $ok;
        print {$out} $self->convert_item($item);
    }
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Formatter - Base class for event stream formatters

=head1 DESCRIPTION

A formatter converts a stream of harness events into a byte representation
(plain text, ANSI-coloured text, JSON, etc.). It sits between the log
layer and the renderer: the renderer decides B<what> to process and B<where>
to write; the formatter decides B<how> each event looks.

Formatters are orthogonal to renderers. A single formatter instance may be
shared across multiple output destinations, or the same formatter class may
be instantiated once per destination with different settings.

=head1 INTERFACE

=over 4

=item $bool = App::Yath2::Formatter->produces_artifact

Class method. Returns true (C<1>) if the byte strings produced by this
formatter are safe to persist as log artifacts — that is, they do not
embed run-specific terminal escape sequences or settings-derived content
that would make them unreadable when replayed outside the original run
context.

Subclasses that embed such content must override this to return C<0>.
The default implementation returns C<1>.

=item $bytes = $formatter->convert_item($item)

Convert a single event hashref to a byte string. Subclasses must override
this method. The base implementation croaks with a helpful message naming
the subclass.

=item $bytes_or_undef = $formatter->append($item, %opts)

Format C<$item> via C<convert_item>.

Without C<out_fh>: returns the formatted byte string.

With C<out_fh =E<gt> $fh>: prints the bytes to C<$fh> and returns nothing.

=item $bytes_or_undef = $formatter->convert($items, %opts)

Format every item in the array-ref C<$items> via C<convert_item> and
concatenate the results.

Without C<out_fh>: returns the concatenated byte string.

With C<out_fh =E<gt> $fh>: prints everything to C<$fh> and returns nothing.

=item $formatter->feed(%opts)

Read a JSONL stream from C<in_fh>, decode each line as JSON, format it
with C<convert_item>, and write the result to C<out_fh>. Both
C<in_fh> and C<out_fh> are required; the method croaks if either is
missing. Blank lines are silently skipped. A line that cannot be decoded
as JSON is a fatal error.

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

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
