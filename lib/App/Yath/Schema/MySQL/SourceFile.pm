use utf8;
package App::Yath::Schema::MySQL::SourceFile;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::SourceFile;

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
__PACKAGE__->table("source_files");
__PACKAGE__->add_columns(
  "source_file_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "filename",
  { data_type => "varchar", is_nullable => 0, size => 512 },
);
__PACKAGE__->set_primary_key("source_file_id");
__PACKAGE__->add_unique_constraint("filename", ["filename"]);
__PACKAGE__->has_many(
  "coverages",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.source_file_id" => "self.source_file_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-04-28 16:05:46
use App::Yath::Schema::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('source_file_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::SourceFile - Autogenerated result class for SourceFile in MySQL.

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
