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

=head2 status

  data_type: 'enum'
  default_value: 'pending'
  extra: {custom_type_name => "queue_status",list => ["pending","running","complete","broken"]}
  is_nullable: 0

=head2 error

  data_type: 'text'
  is_nullable: 1

=head2 project_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 pinned

  data_type: 'boolean'
  default_value: false
  is_nullable: 0

=head2 added

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 status_changed

  data_type: 'timestamp'
  default_value: current_timestamp
  is_nullable: 0
  original: {default_value => \"now()"}

=head2 mode

  data_type: 'enum'
  default_value: 'qvfd'
  extra: {custom_type_name => "run_modes",list => ["summary","qvfd","qvf","complete"]}
  is_nullable: 0

=head2 log_file_id

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 1
  size: 16

=head2 passed

  data_type: 'integer'
  is_nullable: 1

=head2 failed

  data_type: 'integer'
  is_nullable: 1

=head2 retried

  data_type: 'integer'
  is_nullable: 1

=head2 fields

  data_type: 'jsonb'
  is_nullable: 1

=head2 parameters

  data_type: 'jsonb'
  is_nullable: 1

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
  "status",
  {
    data_type => "enum",
    default_value => "pending",
    extra => {
      custom_type_name => "queue_status",
      list => ["pending", "running", "complete", "broken"],
    },
    is_nullable => 0,
  },
  "error",
  { data_type => "text", is_nullable => 1 },
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "pinned",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
  },
  "status_changed",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
    original      => { default_value => \"now()" },
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
  "log_file_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "passed",
  { data_type => "integer", is_nullable => 1 },
  "failed",
  { data_type => "integer", is_nullable => 1 },
  "retried",
  { data_type => "integer", is_nullable => 1 },
  "fields",
  { data_type => "jsonb", is_nullable => 1 },
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
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

=head2 log_file

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::LogFile>

=cut

__PACKAGE__->belongs_to(
  "log_file",
  "Test2::Harness::UI::Schema::Result::LogFile",
  { log_file_id => "log_file_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

=head2 project

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Project>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Test2::Harness::UI::Schema::Result::Project",
  { project_id => "project_id" },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-12-16 15:17:13
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gySvrxM3I+l0bWgk0+Imrw

require DateTime::Format::Pg;

our $VERSION = '0.000028';

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

__PACKAGE__->inflate_column(
    fields => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('fields', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('fields', {}),
    },
);

sub complete {
    my $self = shift;

    my $status = $self->status;

    return 1 if $status eq 'complete';
    return 1 if $status eq 'failed';
    return 0;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Just No.
    delete $cols{log_data};

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{fields} = $self->fields;

    $cols{user} = $self->user->username;
    $cols{project} = $self->project->name;

    my $dt = DateTime::Format::Pg->parse_datetime( $cols{added} );

    # Convert from UTC to localtime
    $dt->set_time_zone('UTC');
    $dt->set_time_zone('local');

    $cols{added} = $dt->strftime("%Y-%m-%d %I:%M%P");

    return \%cols;
}

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
