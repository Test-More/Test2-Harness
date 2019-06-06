package Test2::Harness::Util::Term;
use strict;
use warnings;

our $VERSION = '0.001078';

use Test2::Util qw/IS_WIN32/;

use Importer Importer => 'import';
our @EXPORT_OK = qw/USE_ANSI_COLOR window_size_changed/;

{
    my $use = 0;
    local ($@, $!);

    if (eval { require Term::ANSIColor; Term::ANSIColor->VERSION('4.03') }) {
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
