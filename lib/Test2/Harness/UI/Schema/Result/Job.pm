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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
);

=head1 TABLE: C<jobs>

=cut

__PACKAGE__->table("jobs");

=head1 ACCESSORS

=head2 job_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobs_job_id_seq'

=head2 run_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 0

=head2 yath_job_id

  data_type: 'text'
  is_nullable: 0

=head2 fail

  data_type: 'boolean'
  is_nullable: 1

=head2 file

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "job_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "jobs_job_id_seq",
  },
  "run_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "yath_job_id",
  { data_type => "text", is_nullable => 0 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "file",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_id>

=back

=cut

__PACKAGE__->set_primary_key("job_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<jobs_run_id_job_id_key>

=over 4

=item * L</run_id>

=item * L</job_id>

=back

=cut

__PACKAGE__->add_unique_constraint("jobs_run_id_job_id_key", ["run_id", "job_id"]);

=head1 RELATIONS

=head2 event_links

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLink>

=cut

__PACKAGE__->has_many(
  "event_links",
  "Test2::Harness::UI::Schema::Result::EventLink",
  { "foreign.job_id" => "self.job_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-05 12:00:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:0+9NACa4CL2afcwWVWS/jw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
