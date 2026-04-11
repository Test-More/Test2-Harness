package App::Yath::Schema::DBIC::Result::JobTryField;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_percona format_uuid_for_app format_uuid_for_db/;

use Test2::Harness::Util::JSON qw/decode_json/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("job_try_fields");

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
    "job_try_field_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "job_try_fields_job_try_field_id_seq") : ()),
    },
    "job_try_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "name" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 64,
    },
    "data" => do {
        if (is_sqlite()) {
            +{
                data_type     => "json",
                default_value => \"null",
                is_nullable   => 1,
            };
        }
        elsif (is_postgresql()) {
            +{
                data_type   => "jsonb",
                is_nullable => 1,
            };
        }
        elsif (is_percona()) {
            +{
                data_type   => "json",
                is_nullable => 1,
            };
        }
        else {
            +{
                data_type   => "longtext",
                is_nullable => 1,
            };
        }
    },
    "details" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "raw" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "link" => {
        data_type   => "text",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
);

__PACKAGE__->set_primary_key("job_try_field_id");

__PACKAGE__->belongs_to(
    "job_try" => "App::Yath::Schema::DBIC::Result::JobTry",
    { job_try_id => "job_try_id" },
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

sub TO_JSON {
    my $self = shift;
    my %cols = $self->get_all_fields;
    $cols{data} = decode_json($cols{data}) if $cols{data} && !ref($cols{data});
    return \%cols;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::JobTryField - DBIC Result class for the JobTryField table.

=cut
