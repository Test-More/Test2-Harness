use utf8;
package App::Yath::Schema::MySQL::Email;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Email;

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
__PACKAGE__->table("email");
__PACKAGE__->add_columns(
  "email_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "user_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "verified",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "local",
  { data_type => "varchar", is_nullable => 0, size => 128 },
  "domain",
  { data_type => "varchar", is_nullable => 0, size => 128 },
);
__PACKAGE__->set_primary_key("email_id");
__PACKAGE__->add_unique_constraint("local", ["local", "domain"]);
__PACKAGE__->might_have(
  "email_verification_code",
  "App::Yath::Schema::Result::EmailVerificationCode",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->might_have(
  "primary_email",
  "App::Yath::Schema::Result::PrimaryEmail",
  { "foreign.email_id" => "self.email_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);
__PACKAGE__->belongs_to(
  "user",
  "App::Yath::Schema::Result::User",
  { user_id => "user_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-03 19:08:11
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::Email - Autogenerated result class for Email in MySQL.

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
