use utf8;
package App::Yath::Schema::MySQL::Version;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::Version;

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
__PACKAGE__->table("versions");
__PACKAGE__->add_columns(
  "version",
  { data_type => "decimal", is_nullable => 0, size => [10, 6] },
  "version_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "updated",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "current_timestamp(6)",
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("version_id");
__PACKAGE__->add_unique_constraint("version", ["version"]);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-07-31 16:25:09
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::Version - Autogenerated result class for Version in MySQL.

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
