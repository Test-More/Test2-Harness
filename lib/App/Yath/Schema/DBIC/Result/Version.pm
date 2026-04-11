package App::Yath::Schema::DBIC::Result::Version;
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

__PACKAGE__->table("versions");

__PACKAGE__->add_columns(
    "version" => {
        data_type   => is_mysql() ? "decimal" : "numeric",
        is_nullable => 0,
        size        => [10, 6],
    },
    "version_id" => {
        data_type         => "integer",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "versions_version_id_seq") : ()),
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

__PACKAGE__->set_primary_key("version_id");
__PACKAGE__->add_unique_constraint("version_unique", ["version"]);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Version - DBIC Result class for the Version table.

=cut
