package App::Yath::Schema::DBIC::Result::Reporting;
use utf8;
use strict;
use warnings;

our $VERSION = '2.000011';

use parent 'App::Yath::Schema::DBIC::ResultBase';

use App::Yath::Schema::DBIC qw/is_sqlite is_postgresql is_mysql/;

__PACKAGE__->load_components(
    "InflateColumn::DateTime",
    "InflateColumn::Serializer",
    "InflateColumn::Serializer::JSON",
);

__PACKAGE__->table("reporting");

__PACKAGE__->add_columns(
    "reporting_id" => {
        data_type         => is_sqlite() ? "integer" : "bigint",
        is_auto_increment => 1,
        is_nullable       => 0,
        (is_postgresql() ? (sequence => "reporting_reporting_id_seq") : ()),
    },
    "job_try_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "test_file_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "project_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "user_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "run_id" => {
        data_type      => is_sqlite() ? "integer" : "bigint",
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    "job_try" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 1,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "retry" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 0,
    },
    "abort" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 0,
    },
    "fail" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 0,
    },
    "pass" => {
        data_type   => is_sqlite() ? "smallinteger" : "smallint",
        is_nullable => 0,
    },
    "subtest" => {
        data_type   => "varchar",
        is_nullable => 1,
        size        => 512,
        (is_sqlite() ? (default_value => \"null") : ()),
    },
    "duration" => {
        data_type   => is_mysql() ? "decimal" : "numeric",
        is_nullable => 0,
        size        => [14, 4],
    },
);

__PACKAGE__->set_primary_key("reporting_id");

__PACKAGE__->belongs_to(
    "job_try" => "App::Yath::Schema::DBIC::Result::JobTry",
    { job_try_id => "job_try_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "SET NULL",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "project" => "App::Yath::Schema::DBIC::Result::Project",
    { project_id => "project_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "run" => "App::Yath::Schema::DBIC::Result::Run",
    { run_id => "run_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

__PACKAGE__->belongs_to(
    "test_file" => "App::Yath::Schema::DBIC::Result::TestFile",
    { test_file_id => "test_file_id" },
    {
        is_deferrable => 0,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "NO ACTION",
    },
);

__PACKAGE__->belongs_to(
    "user" => "App::Yath::Schema::DBIC::Result::User",
    { user_id => "user_id" },
    { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath::Schema::DBIC::Result::Reporting - DBIC Result class for the Reporting table.

=cut
