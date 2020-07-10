use utf8;
package Test2::Harness::UI::Schema::Result::Coverage;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Coverage

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=item * L<DBIx::Class::InflateColumn::Serializer>

=item * L<DBIx::Class::InflateColumn::Serializer::JSON>

=item * L<DBIx::Class::Tree::AdjacencyList>

=item * L<DBIx::Class::UUIDColumns>

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
  "UUIDColumns",
);

=head1 TABLE: C<coverage>

=cut

__PACKAGE__->table("coverage");

=head1 ACCESSORS

=head2 job_key

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 file

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "file",
  { data_type => "text", is_nullable => 0 },
);

=head1 RELATIONS

=head2 job_key

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-07-09 22:24:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:MVZA0nTagYV5V40yJxK7kg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
