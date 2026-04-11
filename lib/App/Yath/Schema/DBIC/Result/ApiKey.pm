package App::Yath::Schema::DBIC::Result::ApiKey;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_percona/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("api_keys");

__PACKAGE__->add_columns(
    "value" => do {
        if (is_percona()) {
            +{
                data_type   => "binary",
                is_nullable => 0,
                size        => 16,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "uuid",
                is_nullable => 0,
                size        => 16,
            };
        }
        else {
            +{
                data_type   => "uuid",
                is_nullable => 0,
            };
        }
    },
    "api_key_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "api_keys_api_key_id_seq") : ()),
    },
    "user_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "status" => do {
        if (is_sqlite()) {
            +{
                data_type     => "text",
                default_value => "active",
                is_nullable   => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "enum",
                default_value => "active",
                is_nullable   => 0,
                extra         => {
                    custom_type_name => "api_key_status",
                    list             => ["active", "disabled", "revoked"],
                },
            };
        }
        else {
            +{
                data_type     => "enum",
                default_value => "active",
                is_nullable   => 0,
                extra         => { list => ["active", "disabled", "revoked"] },
            };
        }
    },
    "name" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 128,
    },
);

__PACKAGE__->set_primary_key("api_key_id");
__PACKAGE__->add_unique_constraint("value_unique", ["value"]);

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

App::Yath::Schema::DBIC::Result::ApiKey - DBIC Result class for the ApiKey table.

=cut
