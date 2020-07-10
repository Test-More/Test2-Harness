use utf8;
package Test2::Harness::UI::Schema::Result::Project;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Project

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

=head1 TABLE: C<projects>

=cut

__PACKAGE__->table("projects");

=head1 ACCESSORS

=head2 project_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 name

  data_type: 'citext'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "project_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "name",
  { data_type => "citext", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</project_id>

=back

=cut

__PACKAGE__->set_primary_key("project_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<projects_name_key>

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->add_unique_constraint("projects_name_key", ["name"]);

=head1 RELATIONS

=head2 permissions

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Permission>

=cut

__PACKAGE__->has_many(
  "permissions",
  "Test2::Harness::UI::Schema::Result::Permission",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 runs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-07-09 22:24:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:A0aOG9K6shqb+/244tmiBw

our $VERSION = '0.000028';

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

__END__

=pod

=head1 METHODS

=head1 SOURCE

The source code repository for Test2-Harness-UI can be found at
F<http://github.com/Test-More/Test2-Harness-UI/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2019 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
