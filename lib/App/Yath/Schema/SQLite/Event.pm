use utf8;
package App::Yath::Schema::SQLite::Event;
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
  "event_idx",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "event_id",
  { data_type => "uuid", is_nullable => 0 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0 },
  "is_subtest",
  { data_type => "bool", is_nullable => 0 },
  "is_diag",
  { data_type => "bool", is_nullable => 0 },
  "is_harness",
  { data_type => "bool", is_nullable => 0 },
  "is_time",
  { data_type => "bool", is_nullable => 0 },
  "is_assert",
  { data_type => "bool", is_nullable => 0 },
  "causes_fail",
  { data_type => "bool", is_nullable => 0 },
  "has_binary",
  { data_type => "bool", is_nullable => 0 },
  "has_facets",
  { data_type => "bool", is_nullable => 0 },
  "has_orphan",
  { data_type => "bool", is_nullable => 0 },
  "stamp",
  { data_type => "timestamp", default_value => \"null", is_nullable => 1 },
  "parent_id",
  { data_type => "uuid", default_value => \"null", is_nullable => 1 },
  "trace_id",
  { data_type => "uuid", default_value => \"null", is_nullable => 1 },
  "nested",
  { data_type => "int", default_value => 0, is_nullable => 0 },
);
__PACKAGE__->set_primary_key("event_idx");
__PACKAGE__->add_unique_constraint("event_id_unique", ["event_id"]);
__PACKAGE__->has_many(
  "binaries",
  "App::Yath::Schema::Result::Binary",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->might_have(
  "facet",
  "App::Yath::Schema::Result::Facet",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->belongs_to(
  "job",
  "App::Yath::Schema::Result::Job",
  { job_key => "job_key" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->might_have(
  "orphan",
  "App::Yath::Schema::Result::Orphan",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->might_have(
  "render",
  "App::Yath::Schema::Result::Render",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "reportings",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.event_id" => "self.event_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-21 15:47:43
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::Event - Autogenerated result class for Event in SQLite.

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
