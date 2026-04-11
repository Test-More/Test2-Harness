package App::Yath::Schema::DBIC::Result::Resource;
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

__PACKAGE__->table("resources");

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
    "resource_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "resources_resource_id_seq") : ()),
    },
    "resource_type_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "run_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "host_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    "stamp" => do {
        if (is_sqlite()) {
            +{
                data_type   => "datetime",
                is_nullable => 0,
                size        => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "timestamp with time zone",
                is_nullable => 0,
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                is_nullable               => 0,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                is_nullable               => 0,
            };
        }
    },
    "resource_ord" => {
        data_type   => "integer",
        is_nullable => 0,
    },
    "data" => do {
        if (is_sqlite()) {
            +{
                data_type   => "json",
                is_nullable => 0,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "jsonb",
                is_nullable => 0,
            };
        }
        elsif (is_percona()) {
            +{
                data_type   => "json",
                is_nullable => 0,
            };
        }
        else {
            +{
                data_type   => "longtext",
                is_nullable => 0,
            };
        }
    },
);

__PACKAGE__->set_primary_key("resource_id");
__PACKAGE__->add_unique_constraint("run_id_resource_ord_unique", ["run_id", "resource_ord"]);

__PACKAGE__->belongs_to(
    "host" => "App::Yath::Schema::DBIC::Result::Host",
    { host_id => "host_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "SET NULL",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "resource_type" => "App::Yath::Schema::DBIC::Result::ResourceType",
    { resource_type_id => "resource_type_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "run" => "App::Yath::Schema::DBIC::Result::Run",
    { run_id => "run_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->inflate_column(
    data => {
        inflate => DBIx::Class::InflateColumn::Serializer::JSON->get_unfreezer('data', {}),
        deflate => DBIx::Class::InflateColumn::Serializer::JSON->get_freezer('data', {}),
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

App::Yath::Schema::DBIC::Result::Resource - DBIC Result class for the Resource table.

=cut
