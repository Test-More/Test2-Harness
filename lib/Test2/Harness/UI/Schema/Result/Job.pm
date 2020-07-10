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

=head2 job_key

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 job_id

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 job_try

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

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

=head2 fields

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

=head2 retry

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

=head2 duration

  data_type: 'double precision'
  is_nullable: 1

=head2 pass_count

  data_type: 'bigint'
  is_nullable: 1

=head2 fail_count

  data_type: 'bigint'
  is_nullable: 1

=head2 stdout

  data_type: 'text'
  is_nullable: 1

=head2 stderr

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "job_key",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_try",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "job_ord",
  { data_type => "bigint", is_nullable => 0 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "parameters",
  { data_type => "jsonb", is_nullable => 1 },
  "fields",
  { data_type => "jsonb", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 1 },
  "file",
  { data_type => "text", is_nullable => 1 },
  "fail",
  { data_type => "boolean", is_nullable => 1 },
  "retry",
  { data_type => "boolean", is_nullable => 1 },
  "exit",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  { data_type => "timestamp", is_nullable => 1 },
  "start",
  { data_type => "timestamp", is_nullable => 1 },
  "ended",
  { data_type => "timestamp", is_nullable => 1 },
  "duration",
  { data_type => "double precision", is_nullable => 1 },
  "pass_count",
  { data_type => "bigint", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", is_nullable => 1 },
  "stdout",
  { data_type => "text", is_nullable => 1 },
  "stderr",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_key>

=back

=cut

__PACKAGE__->set_primary_key("job_key");

=head1 UNIQUE CONSTRAINTS

=head2 C<jobs_job_id_job_try_key>

=over 4

=item * L</job_id>

=item * L</job_try>

=back

=cut

__PACKAGE__->add_unique_constraint("jobs_job_id_job_try_key", ["job_id", "job_try"]);

=head1 RELATIONS

=head2 coverages

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Coverage>

=cut

__PACKAGE__->has_many(
  "coverages",
  "Test2::Harness::UI::Schema::Result::Coverage",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.job_key" => "self.job_key" },
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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-07-09 22:41:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:v6GE+/wuAhWW4zZ1SMhB5g

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

sub shortest_file {
    my $self = shift;
    my $file = $self->file or return undef;

    return $1 if $file =~ m{([^/]+)$};
    return $file;
}

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
    $cols{shortest_file} = $self->shortest_file;

    # Inflate
    $cols{parameters} = $self->parameters;
    $cols{fields}     = $self->fields;

    return \%cols;
}

my @GLANCE_FIELDS = qw{ exit fail fail_count job_key job_try retry name pass_count file };
sub glance_data {
    my $self = shift;
    my %cols = $self->get_columns;

    my %data;
    @data{@GLANCE_FIELDS} = @cols{@GLANCE_FIELDS};

    $data{short_file} = $self->short_file;
    $data{shortest_file} = $self->shortest_file;

    # Inflate
    if ($data{fields} = $self->fields) {
        $_->{data} = !!$_->{data} for @{$data{fields}};
    }

    return \%data;
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
