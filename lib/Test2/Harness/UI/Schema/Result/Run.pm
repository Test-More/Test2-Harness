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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);

=head1 TABLE: C<runs>

=cut

__PACKAGE__->table("runs");

=head1 ACCESSORS

=head2 run_ui_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'runs_run_ui_id_seq'

=head2 feed_ui_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 0

=head2 run_id

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "run_ui_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "runs_run_ui_id_seq",
  },
  "feed_ui_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "run_id",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</run_ui_id>

=back

=cut

__PACKAGE__->set_primary_key("run_ui_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<runs_feed_ui_id_run_id_key>

=over 4

=item * L</feed_ui_id>

=item * L</run_id>

=back

=cut

__PACKAGE__->add_unique_constraint("runs_feed_ui_id_run_id_key", ["feed_ui_id", "run_id"]);

=head1 RELATIONS

=head2 feed_ui

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Feed>

=cut

__PACKAGE__->belongs_to(
  "feed_ui",
  "Test2::Harness::UI::Schema::Result::Feed",
  { feed_ui_id => "feed_ui_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);

=head2 jobs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->has_many(
  "jobs",
  "Test2::Harness::UI::Schema::Result::Job",
  { "foreign.run_ui_id" => "self.run_ui_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-02 15:01:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:wmyC64MRs++LZvHRu/W42w

sub user { shift->feed->user }

1;
