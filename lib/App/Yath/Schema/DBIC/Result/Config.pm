package App::Yath::Schema::DBIC::Result::Config;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_postgresql/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("config");

__PACKAGE__->add_columns(
    "config_id" => {
        data_type         => "integer",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "config_config_id_seq") : ()),
    },
    "setting" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 128,
    },
    "value" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 256,
    },
);

__PACKAGE__->set_primary_key("config_id");
__PACKAGE__->add_unique_constraint("setting_unique", ["setting"]);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Config - DBIC Result class for the Config table.

=cut
