use utf8;
package App::Yath::Schema::MySQL::EmailVerificationCode;
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
  "Tree::AdjacencyList",
  "UUIDColumns",
);
__PACKAGE__->table("email_verification_codes");
__PACKAGE__->add_columns(
  "email_idx",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "evcode_id",
  { data_type => "binary", is_nullable => 0, size => 16 },
);
__PACKAGE__->set_primary_key("email_idx");
__PACKAGE__->belongs_to(
  "email",
  "App::Yath::Schema::Result::Email",
  { email_idx => "email_idx" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-21 15:47:35
use App::Yath::Schema::UUID qw/uuid_inflate uuid_deflate/;
__PACKAGE__->inflate_column('evcode_id' => { inflate => \&uuid_inflate, deflate => \&uuid_deflate });
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::EmailVerificationCode - Autogenerated result class for EmailVerificationCode in MySQL.

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
