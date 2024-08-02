use utf8;
package App::Yath::Schema::SQLite::TestFile;
our $VERSION = '2.000004';

package
    App::Yath::Schema::Result::TestFile;

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
__PACKAGE__->table("test_files");
__PACKAGE__->add_columns(
  "test_file_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "filename",
  { data_type => "varchar", is_nullable => 0, size => 255 },
);
__PACKAGE__->set_primary_key("test_file_id");
__PACKAGE__->add_unique_constraint("filename_unique", ["filename"]);
__PACKAGE__->has_many(
  "coverage",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.test_file_id" => "self.test_file_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "jobs",
  "App::Yath::Schema::Result::Job",
  { "foreign.test_file_id" => "self.test_file_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->has_many(
  "reports",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.test_file_id" => "self.test_file_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-08-01 07:24:11
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::TestFile - Autogenerated result class for TestFile in SQLite.

=head1 SEE ALSO

L<App::Yath::Schema::Overlay::TestFile> - Where methods that are not
auto-generated are defined.

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
