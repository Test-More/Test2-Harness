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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
);

=head1 TABLE: C<events>

=cut

__PACKAGE__->table("events");

=head1 ACCESSORS

=head2 event_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'events_event_id_seq'

=head2 job_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 0

=head2 parent_id

  data_type: 'bigint'
  is_foreign_key: 1
  is_nullable: 1

=head2 stamp

  data_type: 'timestamp'
  is_nullable: 1

=head2 processed

  data_type: 'timestamp'
  is_nullable: 1

=head2 is_subtest

  data_type: 'boolean'
  is_nullable: 0

=head2 causes_fail

  data_type: 'boolean'
  is_nullable: 0

=head2 no_display

  data_type: 'boolean'
  is_nullable: 0

=head2 assert_pass

  data_type: 'boolean'
  is_nullable: 1

=head2 plan_count

  data_type: 'integer'
  is_nullable: 1

=head2 f_render

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_about

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_amnesty

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_assert

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_control

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_error

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_info

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_meta

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_parent

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_plan

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_trace

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_job

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_job_end

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_job_exit

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_job_launch

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_job_start

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_harness_run

  data_type: 'jsonb'
  is_nullable: 1

=head2 f_other

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "events_event_id_seq",
  },
  "job_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "parent_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "stamp",
  { data_type => "timestamp", is_nullable => 1 },
  "processed",
  { data_type => "timestamp", is_nullable => 1 },
  "is_subtest",
  { data_type => "boolean", is_nullable => 0 },
  "causes_fail",
  { data_type => "boolean", is_nullable => 0 },
  "no_display",
  { data_type => "boolean", is_nullable => 0 },
  "assert_pass",
  { data_type => "boolean", is_nullable => 1 },
  "plan_count",
  { data_type => "integer", is_nullable => 1 },
  "f_render",
  { data_type => "jsonb", is_nullable => 1 },
  "f_about",
  { data_type => "jsonb", is_nullable => 1 },
  "f_amnesty",
  { data_type => "jsonb", is_nullable => 1 },
  "f_assert",
  { data_type => "jsonb", is_nullable => 1 },
  "f_control",
  { data_type => "jsonb", is_nullable => 1 },
  "f_error",
  { data_type => "jsonb", is_nullable => 1 },
  "f_info",
  { data_type => "jsonb", is_nullable => 1 },
  "f_meta",
  { data_type => "jsonb", is_nullable => 1 },
  "f_parent",
  { data_type => "jsonb", is_nullable => 1 },
  "f_plan",
  { data_type => "jsonb", is_nullable => 1 },
  "f_trace",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_job",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_job_end",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_job_exit",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_job_launch",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_job_start",
  { data_type => "jsonb", is_nullable => 1 },
  "f_harness_run",
  { data_type => "jsonb", is_nullable => 1 },
  "f_other",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_id>

=back

=cut

__PACKAGE__->set_primary_key("event_id");

=head1 RELATIONS

=head2 event_links_buffered_procs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLink>

=cut

__PACKAGE__->has_many(
  "event_links_buffered_procs",
  "Test2::Harness::UI::Schema::Result::EventLink",
  { "foreign.buffered_proc_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 event_links_buffered_raws

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLink>

=cut

__PACKAGE__->has_many(
  "event_links_buffered_raws",
  "Test2::Harness::UI::Schema::Result::EventLink",
  { "foreign.buffered_raw_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 event_links_unbuffered_procs

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLink>

=cut

__PACKAGE__->has_many(
  "event_links_unbuffered_procs",
  "Test2::Harness::UI::Schema::Result::EventLink",
  { "foreign.unbuffered_proc_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 event_links_unbuffered_raws

Type: has_many

Related object: L<Test2::Harness::UI::Schema::Result::EventLink>

=cut

__PACKAGE__->has_many(
  "event_links_unbuffered_raws",
  "Test2::Harness::UI::Schema::Result::EventLink",
  { "foreign.unbuffered_raw_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

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


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-05 12:09:50
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:wS/dGl3SDcdmuj8JzUjq4Q

__PACKAGE__->parent_column('parent_id');

my @STANDARD_FACETS = qw{
    about amnesty assert control error info meta parent plan trace render
};
my @HARNESS_FACETS = qw{
    harness harness_job harness_job_end harness_job_exit harness_job_launch
    harness_job_start harness_run
};

sub STANDARD_FACETS { @STANDARD_FACETS }
sub HARNESS_FACETS  { @HARNESS_FACETS }
sub KNOWN_FACETS    { @STANDARD_FACETS, @HARNESS_FACETS }

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub facet_data {
    my $self = shift;

    my $other = $self->other_facets;
    my %data = $other ? %$other : ();
    @data{@STANDARD_FACETS, @HARNESS_FACETS} = @{$self}{map {"f_$_"} @STANDARD_FACETS, @HARNESS_FACETS};

    return \%data;
}

1;
