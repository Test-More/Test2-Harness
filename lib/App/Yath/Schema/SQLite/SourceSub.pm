use utf8;
package App::Yath::Schema::SQLite::SourceSub;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::SourceSub;

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
__PACKAGE__->table("source_subs");
__PACKAGE__->add_columns(
  "source_sub_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "subname",
  { data_type => "varchar", is_nullable => 0, size => 512 },
);
__PACKAGE__->set_primary_key("source_sub_id");
__PACKAGE__->add_unique_constraint("subname_unique", ["subname"]);
__PACKAGE__->has_many(
  "coverage",
  "App::Yath::Schema::Result::Coverage",
  { "foreign.source_sub_id" => "self.source_sub_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-03 19:08:19
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::SQLite::SourceSub - Autogenerated result class for SourceSub in SQLite.

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
