use utf8;
package App::Yath::Schema::MariaDB::Binary;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::Binary;

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
__PACKAGE__->table("binaries");
__PACKAGE__->add_columns(
  "event_uuid",
  { data_type => "uuid", is_nullable => 0 },
  "binary_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "event_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "is_image",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "filename",
  { data_type => "varchar", is_nullable => 0, size => 512 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "data",
  { data_type => "longblob", is_nullable => 0 },
);
__PACKAGE__->set_primary_key("binary_id");
__PACKAGE__->belongs_to(
  "event",
  "App::Yath::Schema::Result::Event",
  { event_id => "event_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-07-31 16:25:07
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MariaDB::Binary - Autogenerated result class for Binary in MariaDB.

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
