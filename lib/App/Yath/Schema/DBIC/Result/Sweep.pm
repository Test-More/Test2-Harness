package App::Yath::Schema::DBIC::Result::Sweep;
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

__PACKAGE__->table("sweeps");

__PACKAGE__->add_columns(
    "sweep_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "sweeps_sweep_id_seq") : ()),
    },
    "run_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "name" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 64,
    },
);

__PACKAGE__->set_primary_key("sweep_id");
__PACKAGE__->add_unique_constraint("run_id_name_unique", ["run_id", "name"]);

__PACKAGE__->belongs_to(
    "run" => "App::Yath::Schema::DBIC::Result::Run",
    { run_id => "run_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Sweep - DBIC Result class for the Sweep table.

=cut
