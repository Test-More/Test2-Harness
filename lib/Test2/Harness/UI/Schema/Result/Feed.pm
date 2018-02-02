use utf8;
package Test2::Harness::UI::Schema::Result::Feed;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Feed

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

=head1 TABLE: C<feeds>

=cut

__PACKAGE__->table("feeds");

=head1 ACCESSORS

=head2 feed_ui_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'feeds_feed_ui_id_seq'

=head2 user_ui_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 0

=head2 orig_file

  data_type: 'text'
  is_nullable: 0

=head2 local_file

  data_type: 'text'
  is_nullable: 0

=head2 error

  data_type: 'text'
  is_nullable: 1

=head2 stamp

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 permissions

  data_type: 'enum'
  default_value: 'private'
  extra: {custom_type_name => "perms",list => ["private","protected","public"]}
  is_nullable: 0

=head2 status

  data_type: 'enum'
  default_value: 'pending'
  extra: {custom_type_name => "queue_status",list => ["pending","running","complete","failed"]}
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "feed_ui_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "feeds_feed_ui_id_seq",
  },
  "user_ui_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "orig_file",
  { data_type => "text", is_nullable => 0 },
  "local_file",
  { data_type => "text", is_nullable => 0 },
  "error",
  { data_type => "text", is_nullable => 1 },
  "stamp",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
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

=item * L</feed_ui_id>

=back

=cut

__PACKAGE__->set_primary_key("feed_ui_id");

=head1 UNIQUE CONSTRAINTS

=head2 C<feeds_user_ui_id_name_key>

=over 4

=item * L</user_ui_id>

=item * L</name>

=back

=cut

__PACKAGE__->add_unique_constraint("feeds_user_ui_id_name_key", ["user_ui_id", "name"]);

=head1 RELATIONS

=head2 runs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Run>

=cut

__PACKAGE__->has_many(
  "runs",
  "Test2::Harness::UI::Schema::Result::Run",
  { "foreign.feed_ui_id" => "self.feed_ui_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 user_ui

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::User>

=cut

__PACKAGE__->belongs_to(
  "user_ui",
  "Test2::Harness::UI::Schema::Result::User",
  { user_ui_id => "user_ui_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-02 15:01:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:RIXeiRcEO2A6YhqOvggA9w


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
