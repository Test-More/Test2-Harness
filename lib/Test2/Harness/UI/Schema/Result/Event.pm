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

=back

=cut

__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);

=head1 TABLE: C<events>

=cut

__PACKAGE__->table("events");

=head1 ACCESSORS

=head2 event_ui_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'events_event_ui_id_seq'

=head2 job_ui_id

  data_type: 'bigint'
  is_auto_increment: 1
  is_foreign_key: 1
  is_nullable: 0
  sequence: 'events_job_ui_id_seq'

=head2 event_id

  data_type: 'text'
  is_nullable: 0

=head2 stream_id

  data_type: 'text'
  is_nullable: 1

=head2 stamp

  data_type: 'timestamp'
  is_nullable: 1

=head2 processed

  data_type: 'timestamp'
  is_nullable: 1

=head2 causes_fail

  data_type: 'boolean'
  is_nullable: 0

=head2 assert_pass

  data_type: 'boolean'
  is_nullable: 1

=head2 plan_count

  data_type: 'bigint'
  is_nullable: 1

=head2 in_hid

  data_type: 'text'
  is_nullable: 1

=head2 is_hid

  data_type: 'text'
  is_nullable: 1

=head2 about

  data_type: 'jsonb'
  is_nullable: 1

=head2 amnesty

  data_type: 'jsonb'
  is_nullable: 1

=head2 assert

  data_type: 'jsonb'
  is_nullable: 1

=head2 control

  data_type: 'jsonb'
  is_nullable: 1

=head2 error

  data_type: 'jsonb'
  is_nullable: 1

=head2 info

  data_type: 'jsonb'
  is_nullable: 1

=head2 meta

  data_type: 'jsonb'
  is_nullable: 1

=head2 parent

  data_type: 'jsonb'
  is_nullable: 1

=head2 plan

  data_type: 'jsonb'
  is_nullable: 1

=head2 trace

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_job

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_job_end

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_job_exit

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_job_launch

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_job_start

  data_type: 'jsonb'
  is_nullable: 1

=head2 harness_run

  data_type: 'jsonb'
  is_nullable: 1

=head2 other_facets

  data_type: 'jsonb'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "event_ui_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "events_event_ui_id_seq",
  },
  "job_ui_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_foreign_key    => 1,
    is_nullable       => 0,
    sequence          => "events_job_ui_id_seq",
  },
  "event_id",
  { data_type => "text", is_nullable => 0 },
  "stream_id",
  { data_type => "text", is_nullable => 1 },
  "stamp",
  { data_type => "timestamp", is_nullable => 1 },
  "processed",
  { data_type => "timestamp", is_nullable => 1 },
  "causes_fail",
  { data_type => "boolean", is_nullable => 0 },
  "assert_pass",
  { data_type => "boolean", is_nullable => 1 },
  "plan_count",
  { data_type => "bigint", is_nullable => 1 },
  "in_hid",
  { data_type => "text", is_nullable => 1 },
  "is_hid",
  { data_type => "text", is_nullable => 1 },
  "about",
  { data_type => "jsonb", is_nullable => 1 },
  "amnesty",
  { data_type => "jsonb", is_nullable => 1 },
  "assert",
  { data_type => "jsonb", is_nullable => 1 },
  "control",
  { data_type => "jsonb", is_nullable => 1 },
  "error",
  { data_type => "jsonb", is_nullable => 1 },
  "info",
  { data_type => "jsonb", is_nullable => 1 },
  "meta",
  { data_type => "jsonb", is_nullable => 1 },
  "parent",
  { data_type => "jsonb", is_nullable => 1 },
  "plan",
  { data_type => "jsonb", is_nullable => 1 },
  "trace",
  { data_type => "jsonb", is_nullable => 1 },
  "harness",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_job",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_job_end",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_job_exit",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_job_launch",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_job_start",
  { data_type => "jsonb", is_nullable => 1 },
  "harness_run",
  { data_type => "jsonb", is_nullable => 1 },
  "other_facets",
  { data_type => "jsonb", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</event_ui_id>

=back

=cut

__PACKAGE__->set_primary_key("event_ui_id");

=head1 RELATIONS

=head2 job_ui

Type: belongs_to

Related object: L<Test2::Harness::UI::Schema::Result::Job>

=cut

__PACKAGE__->belongs_to(
  "job_ui",
  "Test2::Harness::UI::Schema::Result::Job",
  { job_ui_id => "job_ui_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2018-02-02 15:01:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:9tqcqU8frIwVZTQmWJJdyw

sub run  { shift->job->run }
sub user { shift->job->run->user }

sub facet_data {
    my $self = shift;

    my $other = $self->other_facets;
    my %data = $other ? %$other : ();
    @data{@STANDARD_FACETS, @HARNESS_FACETS} = @{$self}{@STANDARD_FACETS, @HARNESS_FACETS};

    return \%data;
}

1;
