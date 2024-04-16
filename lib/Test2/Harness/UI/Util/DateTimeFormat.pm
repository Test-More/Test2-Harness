package Test2::Harness::UI::Util::DateTimeFormat;
use strict;
use warnings;

use Carp qw/confess/;
use Importer Importer => 'import';

our @EXPORT = qw/DTF/;

my $DTF;
sub DTF {
    return $DTF if $DTF;

    confess "You must first load a Test2::Harness::UI::Schema::NAME module"
        unless $Test2::Harness::UI::Schema::LOADED;

    if ($Test2::Harness::UI::Schema::LOADED =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        return $DTF = 'DateTime::Format::Pg';
    }

    if ($Test2::Harness::UI::Schema::LOADED =~ m/mysql/i) {
        require DateTime::Format::MySQL;
        return $DTF = 'DateTime::Format::MySQL';
    }

    die "Not sure what DateTime::Formatter to use";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::UI::Util::DateTimeFormat - FIXME

=head1 DESCRIPTION

=head1 SYNOPSIS

=head1 EXPORTS

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

