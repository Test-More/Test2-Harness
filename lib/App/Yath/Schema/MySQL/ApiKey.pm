use utf8;
package App::Yath::Schema::MySQL::ApiKey;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::ApiKey;

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
__PACKAGE__->table("api_keys");
__PACKAGE__->add_columns(
  "value",
  { data_type => "uuid", is_nullable => 0 },
  "api_key_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "user_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "status",
  {
    data_type => "enum",
    default_value => "active",
    extra => { list => ["active", "disabled", "revoked"] },
    is_nullable => 0,
  },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 128 },
);
__PACKAGE__->set_primary_key("api_key_id");
__PACKAGE__->add_unique_constraint("value", ["value"]);
__PACKAGE__->belongs_to(
  "user",
  "App::Yath::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-07-31 16:25:09
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::ApiKey - Autogenerated result class for ApiKey in MySQL.

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
