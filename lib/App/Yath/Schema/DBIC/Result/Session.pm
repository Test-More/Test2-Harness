package App::Yath::Schema::DBIC::Result::Session;
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

__PACKAGE__->table("sessions");

__PACKAGE__->add_columns(
    "session_uuid" => do {
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
    "session_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "sessions_session_id_seq") : ()),
    },
    "active" => do {
        if (is_sqlite()) {
            +{
                data_type     => "bool",
                default_value => \"TRUE",
                is_nullable   => 1,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type     => "boolean",
                default_value => \"true",
                is_nullable   => 1,
            };
        }
        else {
            +{
                data_type     => "tinyint",
                default_value => 1,
                is_nullable   => 1,
            };
        }
    },
);

__PACKAGE__->set_primary_key("session_id");
__PACKAGE__->add_unique_constraint("session_uuid_unique", ["session_uuid"]);

__PACKAGE__->has_many(
    "session_hosts" => "App::Yath::Schema::DBIC::Result::SessionHost",
    { "foreign.session_id" => "self.session_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

if (is_percona()) {
    __PACKAGE__->inflate_column(
        'session_uuid' => {
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

App::Yath::Schema::DBIC::Result::Session - DBIC Result class for the Session table.

=cut
