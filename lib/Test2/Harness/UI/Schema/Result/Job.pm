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
  is_nullable: 1

=head2 file

  data_type: 'text'
  is_nullable: 1

=head2 fail

  data_type: 'boolean'
  is_nullable: 1

=head2 retried

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

=head2 pass_count

  data_type: 'bigint'
  is_nullable: 1

=head2 fail_count

  data_type: 'bigint'
  is_nullable: 1

=head2 time_user

  data_type: 'numeric'
  default_value: null
  is_nullable: 1
  size: [20,10]

=head2 time_sys

  data_type: 'numeric'
  default_value: null
  is_nullable: 1
  size: [20,10]

=head2 time_cuser

  data_type: 'numeric'
  default_value: null
  is_nullable: 1
  size: [20,10]

=head2 time_csys

  data_type: 'numeric'
  default_value: null
  is_nullable: 1
  size: [20,10]

=head2 mem_peak

  data_type: 'bigint'
  is_nullable: 1

=head2 mem_size

  data_type: 'bigint'
  is_nullable: 1

=head2 mem_rss

  data_type: 'bigint'
  is_nullable: 1

=head2 mem_peak_u

  data_type: 'varchar'
  default_value: null
  is_nullable: 1
  size: 2

=head2 mem_size_u

  data_type: 'varchar'
  default_value: null
  is_nullable: 1
  size: 2

=head2 mem_rss_u

  data_type: 'varchar'
  default_value: null
  is_nullable: 1
  size: 2

=head2 stdout

  data_type: 'text'
  is_nullable: 1

=head2 stderr

  data_type: 'text'
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
  { data_type => "text", is_nullable => 1 },
  "file",
  { data_type => "text", is_nullable => 1 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "retried",
  { data_type => "boolean", is_nullable => 1 },
  "exit",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  { data_type => "timestamp", is_nullable => 1 },
  "start",
  { data_type => "timestamp", is_nullable => 1 },
  "ended",
  { data_type => "timestamp", is_nullable => 1 },
  "pass_count",
  { data_type => "bigint", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", is_nullable => 1 },
  "time_user",
  {
    data_type => "numeric",
    default_value => \"null",
    is_nullable => 1,
    size => [20, 10],
  },
  "time_sys",
  {
    data_type => "numeric",
    default_value => \"null",
    is_nullable => 1,
    size => [20, 10],
  },
  "time_cuser",
  {
    data_type => "numeric",
    default_value => \"null",
    is_nullable => 1,
    size => [20, 10],
  },
  "time_csys",
  {
    data_type => "numeric",
    default_value => \"null",
    is_nullable => 1,
    size => [20, 10],
  },
  "mem_peak",
  { data_type => "bigint", is_nullable => 1 },
  "mem_size",
  { data_type => "bigint", is_nullable => 1 },
  "mem_rss",
  { data_type => "bigint", is_nullable => 1 },
  "mem_peak_u",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 2,
  },
  "mem_size_u",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 2,
  },
  "mem_rss_u",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 2,
  },
  "stdout",
  { data_type => "text", is_nullable => 1 },
  "stderr",
  { data_type => "text", is_nullable => 1 },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-07-16 09:19:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:8NuQjZoBMCqod6+91SUqKw

our $VERSION = '0.000004';

__PACKAGE__->inflate_column(
    parameters => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('parameters', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('parameters', {}),
    },
);

sub short_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{/(t2?/.*)$}i;
    return $1 if $file =~ m{([^/\\]+\.(?:t2?|pl))$}i;
    return $file;
}

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    $cols{short_file} = $self->short_file;

    # Inflate
    $cols{parameters} = $self->parameters;

    return \%cols;
}

# You can replace this text with custom code or comments, and it will be preserved on regeneration
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
