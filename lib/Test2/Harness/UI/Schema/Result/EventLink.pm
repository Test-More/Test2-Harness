use utf8;
package Test2::Harness::UI::Schema::Result::EventLink;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::EventLink

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

=head1 TABLE: C<event_links>

=cut

__PACKAGE__->table("event_links");

=head1 ACCESSORS

=head2 event_link_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'event_links_event_link_id_seq'

=head2 job_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 0

=head2 yath_eid

  data_type: 'text'
  is_nullable: 0

=head2 trace_hid

  data_type: 'text'
  is_nullable: 0

=head2 buffered_proc_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 1

=head2 unbuffered_proc_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 1

=head2 buffered_raw_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 1

=head2 unbuffered_raw_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_link_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "event_links_event_link_id_seq",
  },
  "job_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "yath_eid",
  { data_type => "text", is_nullable => 0 },
  "trace_hid",
  { data_type => "text", is_nullable => 0 },
  "buffered_proc_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "unbuffered_proc_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "buffered_raw_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "unbuffered_raw_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_link_id>

=back

=cut

__PACKAGE__->set_primary_key("event_link_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<event_links_job_id_yath_eid_trace_hid_key>

=over 4

=item * L</job_id>

=item * L</yath_eid>

=item * L</trace_hid>

=back

=cut

__PACKAGE__->add_unique_constraint(
  "event_links_job_id_yath_eid_trace_hid_key",
  ["job_id", "yath_eid", "trace_hid"],
);

=head1 RELATIONS

=head2 buffered_proc

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "buffered_proc",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "buffered_proc_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

=head2 buffered_raw

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "buffered_raw",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "buffered_raw_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

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

=head2 unbuffered_proc

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "unbuffered_proc",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "unbuffered_proc_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

=head2 unbuffered_raw

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "unbuffered_raw",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "unbuffered_raw_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-05 12:09:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:qm0MM0Zy8rOCg/6WiVCx4Q


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
