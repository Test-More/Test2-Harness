use utf8;
package App::Yath::Schema::MySQL::Host;
our $VERSION = '2.000000';

package
    App::Yath::Schema::Result::Host;

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
__PACKAGE__->table("hosts");
__PACKAGE__->add_columns(
  "host_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "hostname",
  { data_type => "varchar", is_nullable => 0, size => 512 },
);
__PACKAGE__->set_primary_key("host_id");
__PACKAGE__->add_unique_constraint("hostname", ["hostname"]);
__PACKAGE__->has_many(
  "resources",
  "App::Yath::Schema::Result::Resource",
  { "foreign.host_id" => "self.host_id" },
  { cascade_copy => 0, cascade_delete => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-06-04 16:33:48
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::MySQL::Host - Autogenerated result class for Host in MySQL.

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
