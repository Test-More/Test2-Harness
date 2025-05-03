package App::Yath::Schema::DateTimeFormat;
use strict;
use warnings;

our $VERSION = '2.000005';

use Carp qw/confess/;
use Importer Importer => 'import';

our @EXPORT = qw/DTF/;

my $DTF;
sub DTF {
    return $DTF if $DTF;

    confess "You must first load a App::Yath::Schema::NAME module"
        unless $App::Yath::Schema::LOADED;

    if ($App::Yath::Schema::LOADED =~ m/postgresql/i) {
        require DateTime::Format::Pg;
        return $DTF = 'DateTime::Format::Pg';
    }

    if ($App::Yath::Schema::LOADED =~ m/(mysql|mariadb|percona)/i) {
        require DateTime::Format::MySQL;
        return $DTF = 'DateTime::Format::MySQL';
    }

    if ($App::Yath::Schema::LOADED =~ m/sqlite/i) {
        require DateTime::Format::SQLite;
        return $DTF = 'DateTime::Format::SQLite';
    }

    die "Not sure what DateTime::Formatter to use";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DateTimeFormat - FIXME

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


=pod

=cut POD NEEDS AUDIT

