use utf8;
package App::Yath::Schema::PostgreSQL::Config;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::Config;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY ANY PART OF THIS FILE

use strict;
use warnings;

use parent 'App::Yath::Schema::ResultBase';
__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);
__PACKAGE__->table("config");
__PACKAGE__->add_columns(
  "config_id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "config_config_id_seq",
  },
  "setting",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "value",
  { data_type => "varchar", is_nullable => 0, size => 256 },
);
__PACKAGE__->set_primary_key("config_id");
__PACKAGE__->add_unique_constraint("config_setting_key", ["setting"]);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-08-01 07:24:10
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::Config - Autogenerated result class for Config in PostgreSQL.

=head1 SEE ALSO

L<App::Yath::Schema::Overlay::Config> - Where methods that are not
auto-generated are defined.

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
