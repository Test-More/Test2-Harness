package App::Yath::Schema::DBIC::Result::CoverageManager;
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

__PACKAGE__->table("coverage_manager");

__PACKAGE__->add_columns(
    "coverage_manager_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "coverage_manager_coverage_manager_id_seq") : ()),
    },
    "package" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 256,
    },
);

__PACKAGE__->set_primary_key("coverage_manager_id");
__PACKAGE__->add_unique_constraint("package_unique", ["package"]);

__PACKAGE__->has_many(
    "coverage" => "App::Yath::Schema::DBIC::Result::Coverage",
    { "foreign.coverage_manager_id" => "self.coverage_manager_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::CoverageManager - DBIC Result class for the CoverageManager table.

=cut
