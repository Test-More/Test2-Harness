package App::Yath::Schema::DBIC::Result::PrimaryEmail;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("primary_email");

__PACKAGE__->add_columns(
    "user_id" => {
        data_type      => "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "email_id" => {
        data_type      => "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
);

__PACKAGE__->set_primary_key("user_id");
__PACKAGE__->add_unique_constraint("email_id_unique", ["email_id"]);

__PACKAGE__->belongs_to(
    "email" => "App::Yath::Schema::DBIC::Result::Email",
    { email_id => "email_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "user" => "App::Yath::Schema::DBIC::Result::User",
    { user_id => "user_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::PrimaryEmail - DBIC Result class for the PrimaryEmail table.

=cut
