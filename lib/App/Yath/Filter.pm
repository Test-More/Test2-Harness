package App::Yath::Filter;
use strict;
use warnings;

use Filter::Util::Call qw/filter_add/;

our $VERSION = '0.001009';

my $ID = 1;
sub import {
    my $class = shift;
    my ($test) = @_;

    my @lines = (
        "#line " . __LINE__ . ' "' . __FILE__ . "\"\n",
        "package main;\n",
        "\$@ = '';\n",
    );

    my $fh;

    if (ref($test) eq 'CODE') {
        my $ran = 0;

        my $id = $ID++;
        {
            no warnings 'once';
            no strict 'refs';
            *{"run_test_$id"} = $test;
        }

        push @lines => (
            "#line " . __LINE__ . ' "' . __FILE__ . "\"\n",
            "$class\::run_test_$id();\n",
        );
    }
    else {
        require Test2::Harness::Util;
        $fh = Test2::Harness::Util::open_file($test, '<');
        my $safe = $test;
        $safe =~ s/"/\\"/;
        push @lines => (qq{#line 1 "$safe"\n});
    }

    Filter::Util::Call::filter_add(
        bless {
            fh    => $fh,
            lines => \@lines,
            line  => 1,
            test  => $test,
        },
        $class
    );
}

sub filter {
    my $self = shift;

    return 0 if $self->{done};

    my $lines = $self->{lines};
    my $fh    = $self->{fh};

    my ($line, $num);

    if (@$lines) {
        $line = shift @$lines;
    }
    elsif ($fh) {
        $line = <$fh>;
        $num = $self->{line}++;
    }

    if (defined $line) {
        if ($line =~ m/^__(DATA|END)__$/) {
            my $pos = tell($fh);
            my $test = $self->{test};
            $self->{done} = 1;

            # We cannot know for sure what package needs DATA reset, so we
            # inject a BEGIN block to reset it for us.
            $_ .= <<"            EOT";
#line ${ \__LINE__ } "${ \__FILE__ }"
BEGIN { close(DATA); open(DATA, '<', "$test") or die "Could not reopen DATA: \$!"; seek(DATA, $pos, 0) }
            EOT
        }
        else {
            $_ .= $line;
        }

        return 1;
    }

    return 0;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Filter - Source filter used to make yath preload+fork work without
any extra stack frames.

=head1 DESCRIPTION

This is a source filter that allows the C<yath> script to change itself into
your test file post-fork in preload mode.

The "obvious" was to preload+fork would be to preload, then fork, then use
C<do> or C<require> to execute the test file. The problem with the "obvious"
way is that your test file is no longer the bottom of the stack, The code that
called your test file is. This has implications for stack traces, warnings,
caller, and several other things.

Ideally the test file will be the bottom of the stack, no caller. This is
REALLY hard to do. Special form of C<goto &code> cannot do it, and there is no
equivilent for files. We also cannot use exec, that defeats the purpose of
preload.

What this filter does is it prevents the parser from reading the rest of the
originally running script (usually yath itself) and instead returns lines from
the test file. It also uses some C<#line> magic to make sure filename and line
numbers are all correct.

=head1 SYNOPSIS

    #!/usr/bin/perl

    BEGIN {
        my $test_file = do_stuff();
        require App::Yath::Filter;
        App::Yath::Filter->import($test_file);
    }

    die "This statement will never be seen! Lines from the test file will be seen instead.";

Sometimes yath gets codeblocks instead of files, this filter will inject lines
that call the sub in such cases.

    #!/usr/bin/perl

    BEGIN {
        require App::Yath::Filter;
        App::Yath::Filter->import(sub { ok(1, "pass") });
    }

    die "This statement will never be seen!";

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
