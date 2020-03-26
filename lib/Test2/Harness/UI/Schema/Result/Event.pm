use utf8;
package Test2::Harness::UI::Schema::Result::Event;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Test2::Harness::UI::Schema::Result::Event

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

=head1 TABLE: C<events>

=cut

__PACKAGE__->table("events");

=head1 ACCESSORS

=head2 event_id

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 job_key

  data_type: 'uuid'
  is_foreign_key: 1
  is_nullable: 0
  size: 16

=head2 event_ord

  data_type: 'bigint'
  is_nullable: 0

=head2 stamp

  data_type: 'timestamp'
  is_nullable: 1

=head2 parent_id

  data_type: 'uuid'
  is_nullable: 1
  size: 16

=head2 trace_id

  data_type: 'uuid'
  is_nullable: 1
  size: 16

=head2 nested

  data_type: 'integer'
  default_value: 0
  is_nullable: 1

=head2 facets

  data_type: 'jsonb'
  is_nullable: 1

=head2 facets_line

  data_type: 'bigint'
  is_nullable: 1

=head2 orphan

  data_type: 'jsonb'
  is_nullable: 1

=head2 orphan_line

  data_type: 'bigint'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "event_ord",
  { data_type => "bigint", is_nullable => 0 },
  "stamp",
  { data_type => "timestamp", is_nullable => 1 },
  "parent_id",
  { data_type => "uuid", is_nullable => 1, size => 16 },
  "trace_id",
  { data_type => "uuid", is_nullable => 1, size => 16 },
  "nested",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "facets",
  { data_type => "jsonb", is_nullable => 1 },
  "facets_line",
  { data_type => "bigint", is_nullable => 1 },
  "orphan",
  { data_type => "jsonb", is_nullable => 1 },
  "orphan_line",
  { data_type => "bigint", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_id>

=back

=cut

__PACKAGE__->set_primary_key("event_id");

=head1 RELATIONS

=head2 job_key

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->belongs_to(
  "job_key",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-12-16 12:15:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:EbHxcLeZU0l1ydu/xTUvhw

our $VERSION = '0.000028';

__PACKAGE__->parent_column('parent_id');

__PACKAGE__->inflate_column(
    facets => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('facets', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('facets',   {}),
    },
);

__PACKAGE__->inflate_column(
    orphan => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('orphan', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('orphan',   {}),
    },
);

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_columns;

    # Inflate
    $cols{facets} = $self->facets;
    $cols{lines}  = Test2::Formatter::Test2::Composer->render_super_verbose($cols{facets});

    return \%cols;
}

sub line_data {
    my $self = shift;
    my %cols = $self->get_columns;
    my %out;

    # Inflate
    $cols{facets} = $self->facets;
    $out{lines}  = Test2::Formatter::Test2::Composer->render_super_verbose($cols{facets});

    $out{facets} = $cols{facets} ? 1 : 0;
    $out{orphan} = $cols{orphan} ? 1 : 0;

    $out{parent_id} = $cols{parent_id} if $cols{parent_id};
    $out{nested} = $cols{nested} // 0;

    $out{event_id} = $cols{event_id};

    $out{is_parent} = $cols{facets}{parent} ? 1 : 0;

    return \%out;
}

=head2 events

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->has_many(
  "events",
  "Test2::Harness::UI::Schema::Result::Event",
  { "foreign.parent_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 parent_rel

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Event>

=cut

__PACKAGE__->belongs_to(
  "parent_rel",
  "Test2::Harness::UI::Schema::Result::Event",
  { event_id => "parent_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);

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
