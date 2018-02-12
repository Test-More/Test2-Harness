use utf8;
package Test2::Harness::UI::Schema::Result::JobSignoff;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::JobSignoff

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

=head1 TABLE: C<job_signoffs>

=cut

__PACKAGE__->table("job_signoffs");

=head1 ACCESSORS

=head2 job_signoff_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'job_signoffs_job_signoff_id_seq'

=head2 job_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 note

  data_type: 'text'
  is_nullable: 1

=head2 created

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=cut

__PACKAGE__->add_columns(
  "job_signoff_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "job_signoffs_job_signoff_id_seq",
  },
  "job_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "note",
  { data_type => "text", is_nullable => 1 },
  "created",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_signoff_id>

=back

=cut

__PACKAGE__->set_primary_key("job_signoff_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<job_signoffs_job_id_user_id_key>

=over 4

=item * L</job_id>

=item * L</user_id>

=back

=cut

__PACKAGE__->add_unique_constraint("job_signoffs_job_id_user_id_key", ["job_id", "user_id"]);

=head1 RELATIONS

=head2 job

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->belongs_to(
  "job",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_id => "job_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-10 21:26:09
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Q/Suc643CnZQC7vCN/IKVg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
