package App::Yath::Schema::DBIC::Result::Host;
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

__PACKAGE__->table("hosts");

__PACKAGE__->add_columns(
    "host_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "hosts_host_id_seq") : ()),
    },
    "hostname" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 512,
    },
);

__PACKAGE__->set_primary_key("host_id");
__PACKAGE__->add_unique_constraint("hostname_unique", ["hostname"]);

__PACKAGE__->has_many(
    "resources" => "App::Yath::Schema::DBIC::Result::Resource",
    { "foreign.host_id" => "self.host_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Host - DBIC Result class for the Host table.

=cut
