package Test2::Harness::Util::Term;
use strict;
use warnings;

our $VERSION = '0.001001';

use Test2::Util qw/IS_WIN32/;

use Importer Importer => 'import';
our @EXPORT_OK = qw/USE_ANSI_COLOR/;

{
    my $use = 0;
    local ($@, $!);

    if (eval { require Term::ANSIColor }) {
        if (IS_WIN32) {
            if (eval { require Win32::Console::ANSI }) {
                Win32::Console::ANSI->import();
                $use = 1;
            }
        }
        else {
            $use = 1;
        }
    }

    if ($use) {
        *USE_ANSI_COLOR = sub() { 1 };

        my $handle_sig = sub {
            my ($sig) = @_;

            if (-t STDOUT) {
                print STDOUT Term::ANSIColor::color('reset');
                print STDOUT "\r\e[K";
            }

            if (-t STDERR) {
                print STDERR Term::ANSIColor::color('reset');
                print STDERR "\r\e[K";
            }

            print STDERR "\nCaught SIG$sig, exiting\n";
            exit 255;
        };

        $SIG{INT}  = sub { $handle_sig->('INT') };
        $SIG{TERM} = sub { $handle_sig->('TERM') };
    }
    else {
        *USE_ANSI_COLOR = sub() { 0 };
    }
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Util::Term - Terminal utilities for Test2::Harness

=head1 DESCRIPTION

=back

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
