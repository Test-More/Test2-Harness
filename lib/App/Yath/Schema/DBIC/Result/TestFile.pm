package App::Yath::Schema::DBIC::Result::TestFile;
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

__PACKAGE__->table("test_files");

__PACKAGE__->add_columns(
    "test_file_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "test_files_test_file_id_seq") : ()),
    },
    "filename" => {
        data_type   => "varchar",
        is_nullable => 0,
        size        => 255,
    },
);

__PACKAGE__->set_primary_key("test_file_id");
__PACKAGE__->add_unique_constraint("filename_unique", ["filename"]);

__PACKAGE__->has_many(
    "coverage" => "App::Yath::Schema::DBIC::Result::Coverage",
    { "foreign.test_file_id" => "self.test_file_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "jobs" => "App::Yath::Schema::DBIC::Result::Job",
    { "foreign.test_file_id" => "self.test_file_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

__PACKAGE__->has_many(
    "reports" => "App::Yath::Schema::DBIC::Result::Reporting",
    { "foreign.test_file_id" => "self.test_file_id" },
    { cascade_copy => 0, cascade_delete => 1 },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::TestFile - DBIC Result class for the TestFile table.

=cut
