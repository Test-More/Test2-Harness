use utf8;
package Test2::Harness::UI::Schema::Result::Run;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Run

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

=head1 TABLE: C<runs>

=cut

__PACKAGE__->table("runs");

=head1 ACCESSORS

=head2 run_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 name

  data_type: 'text'
  is_nullable: 1

=head2 passed

  data_type: 'integer'
  is_nullable: 1

=head2 failed

  data_type: 'integer'
  is_nullable: 1

=head2 project

  data_type: 'citext'
  is_nullable: 1

=head2 version

  data_type: 'citext'
  is_nullable: 1

=head2 parameters

  data_type: 'jsonb'
  is_nullable: 1

=head2 error

  data_type: 'text'
  is_nullable: 1

=head2 added

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 persist_events

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=head2 permissions

  data_type: 'enum'
  default_value: 'private'
  extra: {custom_type_name => "perms",list => ["private","protected","public"]}
  is_nullable: 0

=head2 mode

  data_type: 'enum'
  default_value: 'qvfd'
  extra: {custom_type_name => "run_modes",list => ["summary","qvfd","qvf","complete"]}
  is_nullable: 0

=head2 store_facets

  data_type: 'enum'
  default_value: 'fail'
  extra: {custom_type_name => "store_toggle",list => ["yes","no","fail"]}
  is_nullable: 0

=head2 store_orphans

  data_type: 'enum'
  default_value: 'fail'
  extra: {custom_type_name => "store_toggle",list => ["yes","no","fail"]}
  is_nullable: 0

=head2 log_file

  data_type: 'text'
  is_nullable: 0

=head2 log_data

  data_type: 'bytea'
  is_nullable: 0

=head2 status

  data_type: 'enum'
  default_value: 'pending'
  extra: {custom_type_name => "queue_status",list => ["pending","running","complete","failed"]}
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "run_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "name",
  { data_type => "text", is_nullable => 1 },
  "passed",
  { data_type => "integer", is_nullable => 1 },
  "failed",
  { data_type => "integer", is_nullable => 1 },
  "project",
  { data_type => "citext", is_nullable => 1 },
  "version",
  { data_type => "citext", is_nullable => 1 },
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
  "error",
  { data_type => "text", is_nullable => 1 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "persist_events",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "permissions",
  {
    data_type => "enum",
    default_value => "private",
    extra => {
      custom_type_name => "perms",
      list => ["private", "protected", "public"],
    },
    is_nullable => 0,
  },
  "mode",
  {
    data_type => "enum",
    default_value => "qvfd",
    extra => {
      custom_type_name => "run_modes",
      list => ["summary", "qvfd", "qvf", "complete"],
    },
    is_nullable => 0,
  },
  "store_facets",
  {
    data_type => "enum",
    default_value => "fail",
    extra => { custom_type_name => "store_toggle", list => ["yes", "no", "fail"] },
    is_nullable => 0,
  },
  "store_orphans",
  {
    data_type => "enum",
    default_value => "fail",
    extra => { custom_type_name => "store_toggle", list => ["yes", "no", "fail"] },
    is_nullable => 0,
  },
  "log_file",
  { data_type => "text", is_nullable => 0 },
  "log_data",
  { data_type => "bytea", is_nullable => 0 },
  "status",
  {
    data_type => "enum",
    default_value => "pending",
    extra => {
      custom_type_name => "queue_status",
      list => ["pending", "running", "complete", "failed"],
    },
    is_nullable => 0,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</run_id>

=back

=cut

__PACKAGE__->set_primary_key("run_id");

=head1 RELATIONS

=head2 jobs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Test2::Harness::UI::Schema::Result::Job",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 run_comments

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::RunComment>

=cut

__PACKAGE__->has_many(
  "run_comments",
  "Test2::Harness::UI::Schema::Result::RunComment",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 run_pins

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::RunPin>

=cut

__PACKAGE__->has_many(
  "run_pins",
  "Test2::Harness::UI::Schema::Result::RunPin",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 run_shares

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::RunShare>

=cut

__PACKAGE__->has_many(
  "run_shares",
  "Test2::Harness::UI::Schema::Result::RunShare",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 signoff

Type: might_have

Related object: L<Test2::Harness::UI::Schema::Result::Signoff>

=cut

__PACKAGE__->might_have(
  "signoff",
  "Test2::Harness::UI::Schema::Result::Signoff",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 user

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::User>

=cut

__PACKAGE__->belongs_to(
  "user",
  "Test2::Harness::UI::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-12 13:38:05
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:THwer4bJG3obBEZkNNFtug

1;
