use utf8;
package App::Yath::Schema::SQLite::Job;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Job;

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
__PACKAGE__->table("jobs");
__PACKAGE__->add_columns(
  "job_idx",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "job_key",
  { data_type => "uuid", is_nullable => 0 },
  "job_id",
  { data_type => "uuid", is_nullable => 0 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0 },
  "test_file_idx",
  {
    data_type      => "bigint",
    default_value  => \"null",
    is_foreign_key => 1,
    is_nullable    => 1,
  },
  "job_try",
  { data_type => "int", default_value => 0, is_nullable => 0 },
  "status",
  { data_type => "text", default_value => "pending", is_nullable => 0 },
  "is_harness_out",
  { data_type => "bool", default_value => \"FALSE", is_nullable => 0 },
  "fail",
  { data_type => "bool", default_value => \"null", is_nullable => 1 },
  "retry",
  { data_type => "bool", default_value => \"null", is_nullable => 1 },
  "name",
  { data_type => "text", default_value => \"null", is_nullable => 1 },
  "exit_code",
  { data_type => "int", default_value => \"null", is_nullable => 1 },
  "launch",
  { data_type => "timestamp", default_value => \"null", is_nullable => 1 },
  "start",
  { data_type => "timestamp", default_value => \"null", is_nullable => 1 },
  "ended",
  { data_type => "timestamp", default_value => \"null", is_nullable => 1 },
  "duration",
  {
    data_type     => "double precision",
    default_value => \"null",
    is_nullable   => 1,
  },
  "pass_count",
  { data_type => "bigint", default_value => \"null", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", default_value => \"null", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_idx");
__PACKAGE__->add_unique_constraint("job_id_job_try_unique", ["job_id", "job_try"]);
__PACKAGE__->add_unique_constraint("job_key_unique", ["job_key"]);
__PACKAGE__->has_many(
  "coverages",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "events",
  "App::Yath::Schema::Result::Event",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "job_fields",
  "App::Yath::Schema::Result::JobField",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "job_outputs",
  "App::Yath::Schema::Result::JobOutput",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->might_have(
  "job_parameter",
  "App::Yath::Schema::Result::JobParameter",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "reportings",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.job_key" => "self.job_key" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->belongs_to(
  "run",
  "App::Yath::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "App::Yath::Schema::Result::TestFile",
  { test_file_idx => "test_file_idx" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-21 15:47:43
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::Job - Autogenerated result class for Job in SQLite.

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
