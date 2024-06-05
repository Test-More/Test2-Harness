use utf8;
package App::Yath::Schema::PostgreSQL::Coverage;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Coverage;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY ANY PART OF THIS FILE

use strict;
use warnings;

use parent 'App::Yath::Schema::ResultBase';
__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
  "UUIDColumns",
);
__PACKAGE__->table("coverage");
__PACKAGE__->add_columns(
  "event_uuid",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "coverage_id",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "coverage_coverage_id_seq",
  },
  "job_try_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "coverage_manager_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "run_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "test_file_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "source_file_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "source_sub_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "metadata",
  { data_type => "jsonb", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("coverage_id");
__PACKAGE__->add_unique_constraint(
  "coverage_run_id_job_try_id_test_file_id_source_file_id_sour_key",
  [
    "run_id",
    "job_try_id",
    "test_file_id",
    "source_file_id",
    "source_sub_id",
  ],
);
__PACKAGE__->belongs_to(
  "coverage_manager",
  "App::Yath::Schema::Result::CoverageManager",
  { coverage_manager_id => "coverage_manager_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "job_try",
  "App::Yath::Schema::Result::JobTry",
  { job_try_id => "job_try_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "SET NULL",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "run",
  "App::Yath::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "source_file",
  "App::Yath::Schema::Result::SourceFile",
  { source_file_id => "source_file_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "source_sub",
  "App::Yath::Schema::Result::SourceSub",
  { source_sub_id => "source_sub_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);
__PACKAGE__->belongs_to(
  "test_file",
  "App::Yath::Schema::Result::TestFile",
  { test_file_id => "test_file_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-04 16:31:50
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::Coverage - Autogenerated result class for Coverage in PostgreSQL.

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
