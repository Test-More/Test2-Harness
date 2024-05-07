use utf8;
package App::Yath::Schema::PostgreSQL::User;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::User;

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
__PACKAGE__->table("users");
__PACKAGE__->add_columns(
  "user_id",
  {
    data_type => "uuid",
    default_value => \"uuid_generate_v4()",
    is_nullable => 0,
    retrieve_on_insert => 1,
    size => 16,
  },
  "username",
  { data_type => "citext", is_nullable => 0 },
  "pw_hash",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 31,
  },
  "pw_salt",
  {
    data_type => "varchar",
    default_value => \"null",
    is_nullable => 1,
    size => 22,
  },
  "realname",
  { data_type => "text", is_nullable => 1 },
  "role",
  {
    data_type => "enum",
    default_value => "user",
    extra => { custom_type_name => "user_type", list => ["admin", "user"] },
    is_nullable => 0,
  },
);
__PACKAGE__->set_primary_key("user_id");
__PACKAGE__->add_unique_constraint("users_username_key", ["username"]);
__PACKAGE__->has_many(
  "api_keys",
  "App::Yath::Schema::Result::ApiKey",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "emails",
  "App::Yath::Schema::Result::Email",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "permissions",
  "App::Yath::Schema::Result::Permission",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->might_have(
  "primary_email",
  "App::Yath::Schema::Result::PrimaryEmail",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "projects",
  "App::Yath::Schema::Result::Project",
  { "foreign.owner" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "reportings",
  "App::Yath::Schema::Result::Reporting",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "runs",
  "App::Yath::Schema::Result::Run",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);
__PACKAGE__->has_many(
  "session_hosts",
  "App::Yath::Schema::Result::SessionHost",
  { "foreign.user_id" => "self.user_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-05-06 17:35:34
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::PostgreSQL::User - Autogenerated result class for User in PostgreSQL.

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
