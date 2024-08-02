package App::Yath::Schema::MariaDB;
use utf8;
use strict;
use warnings;
use Carp();

our $VERSION = '2.000004';

# DO NOT MODIFY THIS FILE, GENERATED BY author_tools/regen_schema.pl


eval { require DBD::mysql; 1 } or die "'DBD::mysql' must be installed, could not load: $@";
eval { require DateTime::Format::MySQL; 1 } or die "'DateTime::Format::MySQL' must be installed, could not load: $@";

Carp::confess("Already loaded schema '$App::Yath::Schema::LOADED'") if $App::Yath::Schema::LOADED;

$App::Yath::Schema::LOADED = "MariaDB";

require App::Yath::Schema;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MariaDB - Autogenerated schema file for MariaDB.

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

