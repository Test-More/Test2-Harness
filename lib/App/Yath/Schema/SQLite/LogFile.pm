use utf8;
package App::Yath::Schema::SQLite::LogFile;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::LogFile;

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
__PACKAGE__->table("log_files");
__PACKAGE__->add_columns(
  "log_file_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "name",
  { data_type => "text", is_nullable => 0 },
  "local_file",
  { data_type => "text", is_nullable => 1 },
  "data",
  { data_type => "longblob", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("log_file_id");
__PACKAGE__->has_many(
  "runs",
  "App::Yath::Schema::Result::Run",
  { "foreign.log_file_id" => "self.log_file_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-10 11:56:39
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::LogFile - Autogenerated result class for LogFile in SQLite.

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