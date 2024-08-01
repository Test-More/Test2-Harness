use utf8;
package App::Yath::Schema::Percona::RunField;
our $VERSION = '2.000003';

package
    App::Yath::Schema::Result::RunField;

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
__PACKAGE__->table("run_fields");
__PACKAGE__->add_columns(
  "event_uuid",
  { data_type => "binary", is_nullable => 0, size => 16 },
  "run_field_id",
  { data_type => "bigint", is_auto_increment => 1, is_nullable => 0 },
  "run_id",
  { data_type => "bigint", is_foreign_key => 1, is_nullable => 0 },
  "name",
  { data_type => "varchar", is_nullable => 0, size => 64 },
  "data",
  { data_type => "json", is_nullable => 1 },
  "details",
  { data_type => "text", is_nullable => 1 },
  "raw",
  { data_type => "text", is_nullable => 1 },
  "link",
  { data_type => "text", is_nullable => 1 },
);
__PACKAGE__->set_primary_key("run_field_id");
__PACKAGE__->belongs_to(
  "run",
  "App::Yath::Schema::Result::Run",
  { run_id => "run_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07052 @ 2024-08-01 07:24:08
__PACKAGE__->inflate_column('event_uuid' => { inflate => \&App::Yath::Schema::Util::format_uuid_for_app, deflate => \&App::Yath::Schema::Util::format_uuid_for_db });
# DO NOT MODIFY ANY PART OF THIS FILE

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::Percona::RunField - Autogenerated result class for RunField in Percona.

=head1 SEE ALSO

L<App::Yath::Schema::Overlay::RunField> - Where methods that are not
auto-generated are defined.

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
