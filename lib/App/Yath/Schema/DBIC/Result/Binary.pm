package App::Yath::Schema::DBIC::Result::Binary;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_percona format_uuid_for_app format_uuid_for_db/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("binaries");

__PACKAGE__->add_columns(
    "event_uuid" => do {
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
    "binary_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "binaries_binary_id_seq") : ()),
    },
    "event_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "is_image" => do {
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
    "filename" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 512,
    },
    "description" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "data" => {
        data_type   => is_postgresql() ? "bytea" : "longblob",
        is_nullable => 0,
    },
);

__PACKAGE__->set_primary_key("binary_id");

__PACKAGE__->belongs_to(
    "event" => "App::Yath::Schema::DBIC::Result::Event",
    { event_id => "event_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "NO ACTION",
    },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'event_uuid' => {
            inflate => \&format_uuid_for_app,
            deflate => \&format_uuid_for_db,
        },
    );
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Binary - DBIC Result class for the Binary table.

=cut
