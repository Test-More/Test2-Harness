use utf8;
package App::Yath::Schema::MySQL::Project;
our $VERSION = '2.000002';

package
    App::Yath::Schema::Result::Project;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY ANY PART OF THIS FILE

use strict;
use warnings;

use parent 'App::Yath::Schema::ResultBase';
__PACKAGE__->load_components(
  "InflateColumn::DateTime",
  "InflateColumn::Serializer",
  "InflateColumn::Serializer::JSON",
);
__PACKAGE__->table("projects");
__PACKAGE__->add_columns(
  "project_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "owner",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 1 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
);
__PACKAGE__->set_primary_key("project_id");
__PACKAGE__->add_unique_constraint("name", ["name"]);
__PACKAGE__->belongs_to(
  "owner",
  "App::Yath::Schema::Result::User",
  { user_id => "owner" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "SET NULL",
    on_update     => "RESTRICT",
  },
);
__PACKAGE__->has_many(
  "permissions",
  "App::Yath::Schema::Result::Permission",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "reports",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "runs",
  "App::Yath::Schema::Result::Run",
  { "foreign.project_id" => "self.project_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-07-31 16:25:09
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::Project - Autogenerated result class for Project in MySQL.

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
