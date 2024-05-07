use utf8;
package App::Yath::Schema::SQLite::Run;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Run;

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
__PACKAGE__->table("runs");
__PACKAGE__->add_columns(
  "run_id",
  { data_type => "uuid", is_nullable => 0 },
  "user_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0 },
  "run_ord",
  { data_type => "int", is_nullable => 0 },
  "status",
  { data_type => "text", is_nullable => 0 },
  "worker_id",
  { data_type => "text", default_value => \"null", is_nullable => 1 },
  "error",
  { data_type => "text", default_value => \"null", is_nullable => 1 },
  "project_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0 },
  "pinned",
  { data_type => "bool", default_value => \"FALSE", is_nullable => 0 },
  "has_coverage",
  { data_type => "bool", default_value => \"FALSE", is_nullable => 0 },
  "added",
  {
    data_type     => "timestamp",
    default_value => \"current_timestamp",
    is_nullable   => 0,
  },
  "duration",
  { data_type => "text", default_value => \"null", is_nullable => 1 },
  "log_file_id",
  {
    data_type      => "uuid",
    default_value  => \"null",
    is_foreign_key => 1,
    is_nullable    => 1,
  },
  "mode",
  { data_type => "text", is_nullable => 0 },
  "buffer",
  { data_type => "text", is_nullable => 0 },
  "passed",
  { data_type => "integer", default_value => \"null", is_nullable => 1 },
  "failed",
  { data_type => "integer", default_value => \"null", is_nullable => 1 },
  "retried",
  { data_type => "integer", default_value => \"null", is_nullable => 1 },
  "concurrency",
  { data_type => "integer", default_value => \"null", is_nullable => 1 },
  "parameters",
  { data_type => "json", default_value => \"null", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("run_id");
__PACKAGE__->add_unique_constraint("run_ord_unique", ["run_ord"]);
__PACKAGE__->has_many(
  "coverages",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "jobs",
  "App::Yath::Schema::Result::Job",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "log_file",
  "App::Yath::Schema::Result::LogFile",
  { log_file_id => "log_file_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "NO ACTION",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "project",
  "App::Yath::Schema::Result::Project",
  { project_id => "project_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);
__PACKAGE__->has_many(
  "reportings",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "resource_batches",
  "App::Yath::Schema::Result::ResourceBatch",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "run_fields",
  "App::Yath::Schema::Result::RunField",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "sweeps",
  "App::Yath::Schema::Result::Sweep",
  { "foreign.run_id" => "self.run_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->belongs_to(
  "user",
  "App::Yath::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 0, on_delete => "NO ACTION", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-06 20:59:06
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::Run - Autogenerated result class for Run in SQLite.

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
