package App::Yath::Schema::DBIC::Result::Email;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("email");

__PACKAGE__->add_columns(
    "email_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "email_email_id_seq") : ()),
    },
    "user_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "verified" => do {
        if (is_sqlite()) {
            +{
                data_type     => "bool",
                default_value => \"FALSE",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "boolean",
                default_value => \"false",
                is_nullable   => 0,
            };
        }
        else {
            +{
                data_type     => "tinyint",
                default_value => 0,
                is_nullable   => 0,
            };
        }
    },
    "local" => {
        data_type   => is_postgresql() ? "citext" : "varchar",
        is_nullable => 0,
        (is_postgresql() ? () : (size => 128)),
    },
    "domain" => {
        data_type   => is_postgresql() ? "citext" : "varchar",
        is_nullable => 0,
        (is_postgresql() ? () : (size => 128)),
    },
);

__PACKAGE__->set_primary_key("email_id");
__PACKAGE__->add_unique_constraint("local_domain_unique", ["local", "domain"]);

__PACKAGE__->might_have(
    "email_verification_code" => "App::Yath::Schema::DBIC::Result::EmailVerificationCode",
    { "foreign.email_id" => "self.email_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->might_have(
    "primary_email" => "App::Yath::Schema::DBIC::Result::PrimaryEmail",
    { "foreign.email_id" => "self.email_id" },
    { cascade_copy => 0, cascade_delete => 1 },
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

App::Yath::Schema::DBIC::Result::Email - DBIC Result class for the Email table.

=cut
