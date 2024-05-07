use utf8;
package App::Yath::Schema::PostgreSQL::Event;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Event;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY ANY PART OF THIS FILE

use strict;
use warnings;

use parent 'App::Yath::Schema::ResultBase';
__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "Tree::AdjacencyList",
  "UUIDColumns",
);
__PACKAGE__->table("events");
__PACKAGE__->add_columns(
  "event_id",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "event_ord",
  { data_type => "bigint", is_nullable => 0 },
  "insert_ord",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "events_insert_ord_seq",
  },
  "is_subtest",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_diag",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_harness",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "is_time",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
  "has_binary",
  { data_type => "boolean", default_value => \"false", is_nullable => 0 },
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
__PACKAGE__->set_primary_key("event_id");
__PACKAGE__->has_many(
  "binaries",
  "App::Yath::Schema::Result::Binary",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "job_key",
  "App::Yath::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->has_many(
  "reportings",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-06 17:35:34
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::Event - Autogenerated result class for Event in PostgreSQL.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
