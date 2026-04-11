package App::Yath::Schema::DBIC::Result::LogFile;
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

__PACKAGE__->table("log_files");

__PACKAGE__->add_columns(
    "log_file_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "log_files_log_file_id_seq") : ()),
    },
    "name" => {
        data_type   => "text",
        is_nullable => 0,
    },
    "local_file" => {
        data_type   => "text",
        is_nullable => 1,
    },
    "data" => {
        data_type   => is_postgresql() ? "bytea" : "longblob",
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key("log_file_id");

__PACKAGE__->has_many(
    "runs" => "App::Yath::Schema::DBIC::Result::Run",
    { "foreign.log_file_id" => "self.log_file_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::LogFile - DBIC Result class for the LogFile table.

=cut
