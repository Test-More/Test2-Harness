use utf8;
package App::Yath::Schema::Percona::JobTry;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::JobTry;

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
__PACKAGE__->table("job_tries");
__PACKAGE__->add_columns(
  "job_try_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "job_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "pass_count",
  { data_type => "bigint", is_nullable => 1 },
  "fail_count",
  { data_type => "bigint", is_nullable => 1 },
  "exit_code",
  { data_type => "integer", is_nullable => 1 },
  "launch",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "start",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "ended",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "status",
  {
    data_type => "enum",
    default_value => "pending",
    extra => {
      list => ["pending", "running", "complete", "broken", "canceled"],
    },
    is_nullable => 0,
  },
  "job_try_ord",
  { data_type => "smallint", is_nullable => 0 },
  "fail",
  { data_type => "tinyint", is_nullable => 1 },
  "retry",
  { data_type => "tinyint", is_nullable => 1 },
  "duration",
  { data_type => "decimal", is_nullable => 1, size => [14, 4] },
  "parameters",
  { data_type => "json", is_nullable => 1 },
  "stdout",
  { data_type => "text", is_nullable => 1 },
  "stderr",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("job_try_id");
__PACKAGE__->add_unique_constraint("job_try_id", ["job_try_id", "job_try_ord"]);
__PACKAGE__->has_many(
  "coverage",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.job_try_id" => "self.job_try_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "events",
  "App::Yath::Schema::Result::Event",
  { "foreign.job_try_id" => "self.job_try_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->belongs_to(
  "job",
  "App::Yath::Schema::Result::Job",
  { job_id => "job_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "RESTRICT" },
);
__PACKAGE__->has_many(
  "job_try_fields",
  "App::Yath::Schema::Result::JobTryField",
  { "foreign.job_try_id" => "self.job_try_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "reports",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.job_try_id" => "self.job_try_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-07-16 15:46:29
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Percona::JobTry - Autogenerated result class for JobTry in Percona.

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
