package App::Yath::Converting;
use strict;
use warnings;

our $VERSION = '1.000155';

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Converting - Things you may need to change in your tests before you can use yath.

=head1 NON-TAP FORMATTER

By default yath tells any L<Test2> or L<Test::Builder> tests to use
L<Test2::Formatter::Stream> instead of L<Test2::Formatter::TAP>. This is done
in order to make sure as much data as possible makes it to yath, TAP is a lossy
formater by comparison.

This is not normally a problem, but tests that do strange things with
STDERR/STDOUT, or try to intercept output from the regular TAP formatter can
have issues with this.

=head2 SOLUTIONS

=head3 HARNESS-NO-STREAM

You can add a harness directive to the top of offending tests that tell the
harness those specific tests should still use the TAP formatter.

    #!/usr/bin/perl
    # HARNESS-NO-STREAM
    ...

This directive can come after the C<#!> line, and after use statements, but
must come BEFORE any empty lines or runtime statements.

=head3 --no-stream

You can run yath with the C<--no-stream> option, which will have tests default
to TAP. This is not recommended as TAP is lossy.

=head1 TESTS ARE RUN VIA FORK BY DEFAULT

The default mode for yath is to preload a few things, then fork to spawn each
test. This is a complicated procedure, and it uses L<goto::file> under the
hood. Sometimes you have tests that simply will not work this way, or tests
that verify specific libraries are not already loaded.

=head2 SOLUTIONS

=head3 HARNESS-NO-PRELOAD

You can use this harness directive inside your tests to tell yath not to fork,
but to instead launch a new perl process to run the test.

    #!/usr/bin/perl
    # HARNESS-NO-PRELOAD
    ...

=head3 --no-fork

=head3 --no-preload

Both these options tell yath not to preload+fork, but to run ALL tests in new
processes. This is slow, it is better to mark specific tests that have issues
in preload mode.

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
