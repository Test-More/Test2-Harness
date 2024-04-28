use utf8;
package App::Yath::Schema::PostgreSQL::EmailVerificationCode;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::EmailVerificationCode;

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
__PACKAGE__->table("email_verification_codes");
__PACKAGE__->add_columns(
  "evcode",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "email_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
);
__PACKAGE__->set_primary_key("email_id");
__PACKAGE__->belongs_to(
  "email",
  "App::Yath::Schema::Result::Email",
  { email_id => "email_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-10 11:56:38
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::EmailVerificationCode - Autogenerated result class for EmailVerificationCode in PostgreSQL.

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
