package App::Yath::Schema::DBIC::Result::Permission;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql is_percona/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("permissions");

__PACKAGE__->add_columns(
    "permission_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "permissions_permission_id_seq") : ()),
    },
    "project_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "user_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "updated" => do {
        if (is_sqlite()) {
            +{
                data_type     => "datetime",
                default_value => \"now",
                is_nullable   => 0,
                size          => 6,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "timestamp with time zone",
                default_value => \"current_timestamp",
                is_nullable   => 0,
                original      => { default_value => \"now()" },
            };
        }
        elsif (is_percona()) {
            +{
                data_type                 => "datetime",
                datetime_undef_if_invalid => 1,
                default_value             => "CURRENT_TIMESTAMP",
                is_nullable               => 0,
            };
        }
        else {
            +{
                data_type                 => "timestamp",
                datetime_undef_if_invalid => 1,
                default_value             => "current_timestamp(6)",
                is_nullable               => 0,
            };
        }
    },
);

__PACKAGE__->set_primary_key("permission_id");
__PACKAGE__->add_unique_constraint("project_id_user_id_unique", ["project_id", "user_id"]);

__PACKAGE__->belongs_to(
    "project" => "App::Yath::Schema::DBIC::Result::Project",
    { project_id => "project_id" },
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

App::Yath::Schema::DBIC::Result::Permission - DBIC Result class for the Permission table.

=cut
