package App::Yath::Filter;
use strict;
use warnings;

use Filter::Util::Call qw/filter_add/;

our $VERSION = '0.001008';

sub import {
    no warnings 'once';
    my $class = shift;
    my ($test) = @_;

    Filter::Util::Call::filter_add(bless {}, $class);

    my @lines = (
        "#line " . __LINE__ . ' "' . __FILE__ . "\"\n",
        "package main;\n",
        # Do not keep these signal handlers post-fork when we are running a test file.
        "\$SIG{HUP}  = 'DEFAULT';\n",
        "\$SIG{INT}  = 'DEFAULT';\n",
        "\$SIG{TERM} = 'DEFAULT';\n",

        "\$@ = '';\n",
    );

    my $fh;

    *filter = sub {
        my $line;

        if (@lines) {
            $line = shift @lines;
        }
        elsif ($fh) {
            $line = <$fh>;
        }

        if (defined $line) {
            $_ .= $line;
            return 1;
        }

        return 0;
    };

    if (ref($test) eq 'CODE') {
        my $ran = 0;

        *run_test = $test;

        push @lines => (
            "#line " . __LINE__ . ' "' . __FILE__ . "\"\n",
            "$class\::run_test();\n",
        );
    }
    else {
        require Test2::Harness::Util;
        $fh = Test2::Harness::Util::open_file($test, '<');

        push @lines => (
            qq{#line 1 "$test"\n},
        );
    }
}

1;
