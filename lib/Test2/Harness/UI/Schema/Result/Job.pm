use utf8;
package Test2::Harness::UI::Schema::Result::Job;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Job

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

=head1 TABLE: C<jobs>

=cut

__PACKAGE__->table("jobs");

=head1 ACCESSORS

=head2 job_id

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 job_ord

  data_type: 'bigint'
  is_nullable: 0

=head2 run_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 parameters

  data_type: 'jsonb'
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 file

  data_type: 'text'
  is_nullable: 1

=head2 fail

  data_type: 'boolean'
  is_nullable: 1

=head2 exit

  data_type: 'integer'
  is_nullable: 1

=head2 launch

  data_type: 'timestamp'
  is_nullable: 1

=head2 start

  data_type: 'timestamp'
  is_nullable: 1

=head2 ended

  data_type: 'timestamp'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "job_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_ord",
  { data_type => "bigint", is_nullable => 0 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "file",
  { data_type => "text", is_nullable => 1 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "exit",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  { data_type => "timestamp", is_nullable => 1 },
  "start",
  { data_type => "timestamp", is_nullable => 1 },
  "ended",
  { data_type => "timestamp", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_id>

=back

=cut

__PACKAGE__->set_primary_key("job_id");

=head1 RELATIONS

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.job_id" => "self.job_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 job_signoffs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::JobSignoff>

=cut

__PACKAGE__->has_many(
  "job_signoffs",
  "Test2::Harness::UI::Schema::Result::JobSignoff",
  { "foreign.job_id" => "self.job_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 run

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->belongs_to(
  "run",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-11 19:33:16
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:i4Da/Y8HOPzaW7ag88VElg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
