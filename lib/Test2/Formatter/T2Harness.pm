package Test2::Formatter::T2Harness;
use strict;
use warnings;

our $VERSION = '0.000014';

sub new {
    my $class = shift;

    $| = 1;
    my $orig = select STDERR;
    $| = 1;
    select STDOUT;
    $| = 1;
    select $orig;

    if ($INC{'Test/Builder.pm'}) {
        print "# Selecting Test::Builder::Formatter.\n";
        eval { require Test::Builder::Formatter; 1 } and return Test::Builder::Formatter->new(@_);

        die "Test::Builder is loaded, but Test::Builder::Formatter is not present.\nAre you trying to combine old Test::Builder with Test2?\n";
    }

    if (-t STDOUT) {
        print "# Selecting Test2::Formatter::TAP.\n";
        require Test2::Formatter::TAP;
        return Test2::Formatter::TAP->new(@_);
    }

    # This formatter announces itself, no need to print it.
    require Test2::Formatter::EventStream;
    return Test2::Formatter::EventStream->new(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Formatter::T2Harness - Formatter that will select the best formatter for
the job.

=head1 DESCRIPTION

Calling C<new()> on this class will return an instance of either
L<Test::Builder::Formatter>, L<Test2::Formatter::TAP>, or
L<Test2::Formatter::EventStream>.

If Test::Builder is loaded it will return a Test::Builder::Formatter instance.

If Test::Builder is not loaded, but STDOUT is a terminal, TAP will be used.

Falls back to Test2::Formatter::EventStream for use by L<Test2::Harness>.

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

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
