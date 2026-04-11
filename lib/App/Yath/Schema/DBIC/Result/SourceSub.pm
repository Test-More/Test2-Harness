package App::Yath::Schema::DBIC::Result::SourceSub;
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

__PACKAGE__->table("source_subs");

__PACKAGE__->add_columns(
    "source_sub_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "source_subs_source_sub_id_seq") : ()),
    },
    "subname" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 512,
    },
);

__PACKAGE__->set_primary_key("source_sub_id");
__PACKAGE__->add_unique_constraint("subname_unique", ["subname"]);

__PACKAGE__->has_many(
    "coverage" => "App::Yath::Schema::DBIC::Result::Coverage",
    { "foreign.source_sub_id" => "self.source_sub_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::SourceSub - DBIC Result class for the SourceSub table.

=cut
