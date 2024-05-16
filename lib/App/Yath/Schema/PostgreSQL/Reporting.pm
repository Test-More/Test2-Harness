use utf8;
package App::Yath::Schema::PostgreSQL::Reporting;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Reporting;

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
__PACKAGE__->table("reporting");
__PACKAGE__->add_columns(
  "reporting_idx",
  {
    data_type         => "bigint",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "reporting_reporting_idx_seq",
  },
  "project_idx",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "user_idx",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "run_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 0, size => 16 },
  "test_file_idx",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "job_key",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "event_id",
  { data_type => "uuid", is_foreign_key => 1, is_nullable => 1, size => 16 },
  "job_try",
  { data_type => "integer", is_nullable => 1 },
  "subtest",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 512,
  },
  "duration",
  { data_type => "double precision", is_nullable => 0 },
  "fail",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "pass",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "retry",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
  "abort",
  { data_type => "smallint", default_value => 0, is_nullable => 0 },
);
__PACKAGE__->set_primary_key("reporting_idx");
__PACKAGE__->belongs_to(
  "event",
  "App::Yath::Schema::Result::Event",
  { event_id => "event_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "job",
  "App::Yath::Schema::Result::Job",
  { job_key => "job_key" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);
__PACKAGE__->belongs_to(
  "project",
  "App::Yath::Schema::Result::Project",
  { project_idx => "project_idx" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
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
__PACKAGE__->belongs_to(
  "user",
  "App::Yath::Schema::Result::User",
  { user_idx => "user_idx" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-15 16:47:41
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::Reporting - Autogenerated result class for Reporting in PostgreSQL.

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
