package Getopt::Yath::Term;
use strict;
use warnings;

our $VERSION = '2.000000';

our @EXPORT = qw/color USE_COLOR term_size fit_to_width/;
use Importer Importer => 'import';

use Term::Table::Util qw/term_size/;

BEGIN {
    if (eval { require Term::ANSIColor; 1 }) {
        *USE_COLOR = sub() { 1 };
        *color = \&Term::ANSIColor::color;
    }
    else {
        *USE_COLOR = sub() { 0 };
        *color = sub { '' };
    }
}

sub fit_to_width {
    my ($join, $text, %params) = @_;

    my $prefix = $params{prefix};
    my $width  = $params{width};
    unless (defined $width) {
        $width = term_size() - 20;
        $width = 80 unless $width && $width >= 80;
    }

    my @parts = ref($text) ? @$text : split /\s+/, $text;

    my @out;

    my $line = "";
    for my $part (@parts) {
        my $new = $line ? "$line$join$part" : $part;

        if ($line && length($new) > $width) {
            push @out => $line;
            $line = $part;
        }
        else {
            $line = $new;
        }
    }
    push @out => $line if $line;

    if(defined $prefix) {
        $_ =~ s/^/  /gm for @out;
    }

    return join "\n" => @out;
}

1;
