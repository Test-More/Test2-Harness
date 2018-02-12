use utf8;
package Test2::Harness::UI::Schema::Result::EventComment;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::EventComment

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

=head1 TABLE: C<event_comments>

=cut

__PACKAGE__->table("event_comments");

=head1 ACCESSORS

=head2 event_comment_id

  data_type: 'uuid'
  default_value: uuid_generate_v4()
  is_nullable: 0
  size: 16

=head2 event_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 user_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 created

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 content

  data_type: 'text'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "event_comment_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    size => 16,
  },
  "event_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "created",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "content",
  { data_type => "text", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_comment_id>

=back

=cut

__PACKAGE__->set_primary_key("event_comment_id");

=head1 RELATIONS

=head2 event

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "event",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "event_id" },
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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-12 08:17:03
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:wwjQ7gSWO3DNTfonb1wtuA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
