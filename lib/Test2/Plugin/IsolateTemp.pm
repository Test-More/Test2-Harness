package Test2::Plugin::IsolateTemp;
use strict;
use warnings;

our $VERSION = '2.000005';

use Test2::Harness::Util qw/chmod_tmp/;
use File::Temp qw/tempdir/;

our $tempdir;

if ($ENV{TEST2_HARNESS_ACTIVE}) {
    # Nothing currently
}
else {
    my $template = join '-' => ("T2ISO", $$, "XXXX");

    $tempdir = tempdir(
        $template,
        TMPDIR  => 1,
        CLEANUP => 1,
    );

    chmod_tmp($tempdir);

    $ENV{TMPDIR}   = $tempdir;
    $ENV{TEMPDIR}  = $tempdir;
    $ENV{TMP_DIR}  = $tempdir;
    $ENV{TEMP_DIR} = $tempdir;
}


1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Plugin::IsolateTemp - Make sure a test uses an isolated temp dir.

=head1 DESCRIPTION

Make sure the test uses an isolated temp dir.

B<NOTE:> This is a no-op when tests are run with yath (L<App::Yath> and
L<Test2::Harness>) as yath will do this by default.

=head1 SYNOPSIS

    use Test2::Plugin::IsolateTemp;

=over 4

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
