package App::Yath::Schema::DBIC::Result::ResourceType;
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

__PACKAGE__->table("resource_types");

__PACKAGE__->add_columns(
    "resource_type_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "resource_types_resource_type_id_seq") : ()),
    },
    "name" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 512,
    },
);

__PACKAGE__->set_primary_key("resource_type_id");
__PACKAGE__->add_unique_constraint("name_unique", ["name"]);

__PACKAGE__->has_many(
    "resources" => "App::Yath::Schema::DBIC::Result::Resource",
    { "foreign.resource_type_id" => "self.resource_type_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::ResourceType - DBIC Result class for the ResourceType table.

=cut
