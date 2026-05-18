package App::Yath2::Formatter::Tty;
use strict;
use warnings;

our $VERSION = '2.000013';

use parent 'App::Yath2::Formatter';

use App::Yath2::Formatter::Txt;
use Carp qw/croak/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Object::HashBase qw{
    <color_mode
    <theme
    +_txt
    +_palette
};

# Setting-bearing: output varies with color_mode/theme. Never persisted.
sub produces_artifact { 0 }

my %DEFAULT_PALETTE = (
    PASS    => "\e[32m",      # green
    FAIL    => "\e[31m",      # red
    HALT    => "\e[1;31m",    # bright red
    HARNESS => "\e[36m",      # cyan
    INFO    => "\e[37m",      # light gray
    DEBUG   => "\e[33m",      # yellow
    DIAG    => "\e[33m",      # yellow
    NOTE    => "\e[34m",      # blue
    SKIP    => "\e[36m",      # cyan
    TODO    => "\e[35m",      # magenta
    ERROR   => "\e[31m",      # red
    FATAL   => "\e[1;31m",    # bright red
    PLAN    => "\e[37m",      # light gray
);
my $RESET = "\e[0m";

sub init {
    my $self = shift;
    $self->{+COLOR_MODE} //= 'auto';
    $self->{+THEME}      //= 'default';
    $self->{+_TXT}     = App::Yath2::Formatter::Txt->new;
    $self->{+_PALETTE} = {%DEFAULT_PALETTE};
    return;
}

# Determine whether to actually emit ANSI based on color_mode + output fh.
# Without an out_fh (return-string mode), we follow color_mode as-is,
# treating the absence of a filehandle as non-TTY for auto mode.
sub _use_color {
    my ($self, $out_fh) = @_;
    my $mode = $self->{+COLOR_MODE};
    return 1 if $mode eq 'always';
    return 0 if $mode eq 'never';
    # auto: emit color only when the output filehandle is a TTY.
    return 0 unless $out_fh;
    return -t $out_fh ? 1 : 0;
}

# convert_item returns plain (uncolored) text. Colorization is applied in
# append/convert/feed based on whether the output filehandle is a TTY.
sub convert_item {
    my ($self, $item) = @_;
    return $self->{+_TXT}->convert_item($item);
}

sub append {
    my ($self, $item, %opts) = @_;
    my $bytes = $self->{+_TXT}->convert_item($item);
    $bytes = $self->_colorize($bytes) if $self->_use_color($opts{out_fh});
    if (my $fh = $opts{out_fh}) {
        print {$fh} $bytes;
        return;
    }
    return $bytes;
}

sub convert {
    my ($self, $items, %opts) = @_;
    my $out = '';
    $out .= $self->{+_TXT}->convert_item($_) for @$items;
    $out = $self->_colorize($out) if $self->_use_color($opts{out_fh});
    if (my $fh = $opts{out_fh}) {
        print {$fh} $out;
        return;
    }
    return $out;
}

sub feed {
    my ($self, %opts) = @_;
    my $in    = $opts{in_fh}  or croak "in_fh required";
    my $out   = $opts{out_fh} or croak "out_fh required";
    my $color = $self->_use_color($out);
    while (my $line = <$in>) {
        chomp $line;
        next unless length $line;
        my $item;
        my $ok  = eval { $item = decode_json($line); 1 };
        my $err = $@;
        die "Failed to decode JSONL line: $err" unless $ok;
        my $bytes = $self->{+_TXT}->convert_item($item);
        $bytes = $self->_colorize($bytes) if $color;
        print {$out} $bytes;
    }
    return;
}

# Colorize line-by-line. Recognises two tag forms emitted by Txt:
#   Regular tags:  TAG: rest           (e.g. "PASS: foo")
#   Amnesty tags:  ! TAG !: rest       (e.g. "! PASS !: foo")
# Leading indentation (spaces) is preserved outside the color span.
sub _colorize {
    my ($self, $bytes) = @_;
    my $pal = $self->{+_PALETTE};
    my @out;
    for my $line (split /(\n)/, $bytes) {
        # Match amnesty form:  <indent>! TAG !: rest
        if ($line =~ /^(\s*)(!\s*([A-Z][A-Z_]*)\s*!:)([ \t]*.*)$/s) {
            my ($indent, $marker, $tag, $rest) = ($1, $2, $3, $4);
            if (my $code = $pal->{$tag}) {
                push @out => "${indent}${code}${marker}${RESET}${rest}";
                next;
            }
        }
        # Match regular form:  <indent>TAG: rest
        elsif ($line =~ /^(\s*)([A-Z][A-Z_]*:)([ \t]*.*)$/s) {
            my ($indent, $marker, $rest) = ($1, $2, $3);
            (my $tag = $marker) =~ s/:$//;
            if (my $code = $pal->{$tag}) {
                push @out => "${indent}${code}${marker}${RESET}${rest}";
                next;
            }
        }
        push @out => $line;
    }
    return join('', @out);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Formatter::Tty - ANSI-colorized event formatter for terminal output

=head1 DESCRIPTION

A setting-bearing formatter that layers ANSI escape sequences and color over
the canonical plain-text output produced by L<App::Yath2::Formatter::Txt>.
Because the output depends on C<color_mode> and C<theme>, it is never
safe to persist as a log artifact; C<produces_artifact> returns C<0>.

Color is applied line-by-line: each line's leading tag (C<PASS:>, C<FAIL:>,
C<HARNESS:>, etc., including the amnesty form C<! PASS !:>) is matched against
a palette and wrapped in an ANSI color + reset pair. Lines whose tags are not
in the palette pass through unchanged.

=head1 COLOR MODES

=over 4

=item auto (default)

Emit ANSI color only when the output filehandle is a TTY (C<-t $fh>). When
no output filehandle is given (return-string mode), color is suppressed.

=item always

Always emit ANSI escape sequences regardless of whether the output is a TTY.

=item never

Never emit ANSI escape sequences.

=back

=head1 INTERFACE

=over 4

=item $bool = App::Yath2::Formatter::Tty->produces_artifact

Returns C<0>. Tty output embeds terminal escape sequences and is driven by
settings; it is not safe to persist as a replay artifact.

=item $formatter = App::Yath2::Formatter::Tty->new(%opts)

Construct a new formatter. Accepted options:

=over 4

=item color_mode => 'auto' | 'always' | 'never'

Controls ANSI color emission. Defaults to C<auto>.

=item theme => $name

Named color theme. Currently only C<default> is defined. Defaults to
C<default>.

=back

=item $bytes = $formatter->convert_item($item)

Convert a single event hashref to plain text (no color). Delegates to the
internal L<App::Yath2::Formatter::Txt> instance. Colorization is applied by
C<append>/C<convert>/C<feed> based on the output filehandle.

=item $bytes_or_undef = $formatter->append($item, %opts)

Format C<$item> and optionally colorize. Accepts C<out_fh> in C<%opts>.

=item $bytes_or_undef = $formatter->convert($items, %opts)

Format every item in C<$items> and concatenate. Accepts C<out_fh> in C<%opts>.

=item $formatter->feed(%opts)

Read a JSONL stream from C<in_fh>, format each event, and write to C<out_fh>.
Both C<in_fh> and C<out_fh> are required. Color is decided once per call based
on whether C<out_fh> is a TTY.

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
