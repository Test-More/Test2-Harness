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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);

=head1 TABLE: C<jobs>

=cut

__PACKAGE__->table("jobs");

=head1 ACCESSORS

=head2 job_ui_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'jobs_job_ui_id_seq'

=head2 run_ui_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 0

=head2 job_id

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
  "job_ui_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "jobs_job_ui_id_seq",
  },
  "run_ui_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "job_id",
  { data_type => "text", is_nullable => 0 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "file",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_ui_id>

=back

=cut

__PACKAGE__->set_primary_key("job_ui_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<jobs_run_ui_id_job_id_key>

=over 4

=item * L</run_ui_id>

=item * L</job_id>

=back

=cut

__PACKAGE__->add_unique_constraint("jobs_run_ui_id_job_id_key", ["run_ui_id", "job_id"]);

=head1 RELATIONS

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.job_ui_id" => "self.job_ui_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 run_ui

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->belongs_to(
  "run_ui",
  "Test2::Harness::UI::Schema::Result::Run",
  { run_ui_id => "run_ui_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-02 15:01:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:XMMxbVfmP/lX+tFdnqhgFg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
